import XCTest

@MainActor
final class AynaSmokeUITests: AynaUITestCase {
    func testConversationCreationShowsMockResponse() {
        composeInitialMessageAndSend("Hello UI Tests")

        let responsePredicate = NSPredicate(format: "label CONTAINS %@", "UI Test Response")
        let responseLabel = app.staticTexts.containing(responsePredicate).firstMatch
        let textViewPredicate = NSPredicate(format: "value CONTAINS %@", "UI Test Response")
        let responseTextView = app.textViews.containing(textViewPredicate).firstMatch
        let genericResponse = app.otherElements.containing(
            NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "UI Test Response",
                "UI Test Response"
            )
        ).firstMatch

        let foundResponse = responseLabel.waitForExistence(timeout: 10)
            || responseTextView.waitForExistence(timeout: 10)
            || genericResponse.waitForExistence(timeout: 10)
        XCTAssertTrue(foundResponse)

        let chatComposer = app.textViews[TestIdentifiers.ChatComposer.textEditor]
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 10))
        XCTAssertEqual((chatComposer.value as? String) ?? "", "")

        let conversationTitle = app.staticTexts["Hello UI Tests"]
        XCTAssertTrue(conversationTitle.waitForExistence(timeout: 10))
    }

    func testNewConversationButtonResetsComposer() {
        composeInitialMessageAndSend("First chat")

        let newConversationButton = app.buttons[TestIdentifiers.Sidebar.newConversationButton]
            .firstMatch
        XCTAssertTrue(newConversationButton.waitForExistence(timeout: 10))
        newConversationButton.click()

        let composer = app.textViews[TestIdentifiers.NewChatComposer.textEditor]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual((composer.value as? String) ?? "", "")
    }

    func testSearchConversations() {
        let uniqueKeyword = "UniqueSearchTerm"
        composeInitialMessageAndSend("Message with \(uniqueKeyword)")

        let title = "Message with \(uniqueKeyword)"
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))
        let rowIdentifierPrefix = "sidebar.conversationRow."
        let matchingTitlePrefix = String(title.prefix(16))
        let matchingRowTitlePredicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND value BEGINSWITH %@",
            rowIdentifierPrefix,
            matchingTitlePrefix
        )
        let matchingRowTitle = app.staticTexts.matching(matchingRowTitlePredicate).firstMatch
        XCTAssertTrue(matchingRowTitle.waitForExistence(timeout: 10))
        let matchingRowIdentifier = matchingRowTitle.identifier

        composeInitialMessageAndSend("Another conversation")
        let otherTitle = "Another conversation"
        let sidebarTitlePredicate = NSPredicate(
            format: "identifier BEGINSWITH %@ AND value == %@",
            rowIdentifierPrefix,
            otherTitle
        )
        let nonMatchingTitles = app.staticTexts.matching(sidebarTitlePredicate)
        XCTAssertTrue(nonMatchingTitles.firstMatch.waitForExistence(timeout: 10))

        let searchField = app.textFields[TestIdentifiers.Sidebar.searchField]
        XCTAssertTrue(searchField.exists)
        searchField.click()
        searchField.typeText(uniqueKeyword)

        let titleDisappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 0"),
            object: nonMatchingTitles
        )
        XCTAssertEqual(XCTWaiter.wait(for: [titleDisappeared], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts.matching(identifier: matchingRowIdentifier).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["No results found"].exists)
    }

    func testDeleteConversation() {
        let msg = "Conversation to delete"
        composeInitialMessageAndSend(msg)

        let sidebarList = app.outlines[TestIdentifiers.Sidebar.conversationList]
        let title = sidebarList.staticTexts[msg]
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        let rowHittablePredicate = NSPredicate(format: "isHittable == true")
        let rowHittableExpectation = XCTNSPredicateExpectation(predicate: rowHittablePredicate, object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [rowHittableExpectation], timeout: 5), .completed)

        title.rightClick()

        let deleteMenuItem = app.menuItems["contextMenu.delete"]
        XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 3), "Delete menu item should appear in context menu")
        deleteMenuItem.click()

        let doesNotExist = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: doesNotExist, object: title)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Context menu Delete should remove the conversation from the sidebar")
    }

    func testDeleteConversationWithKeyboard() {
        let msg = "Conversation to delete via keyboard"
        composeInitialMessageAndSend(msg)

        let sidebarList = app.outlines[TestIdentifiers.Sidebar.conversationList]
        let title = sidebarList.staticTexts[msg]
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        let rowHittablePredicate = NSPredicate(format: "isHittable == true")
        let rowHittableExpectation = XCTNSPredicateExpectation(predicate: rowHittablePredicate, object: title)
        XCTAssertEqual(XCTWaiter.wait(for: [rowHittableExpectation], timeout: 5), .completed)

        title.click()
        app.typeKey(.delete, modifierFlags: [])

        let doesNotExist = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: doesNotExist, object: title)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Delete key should remove the selected conversation from the sidebar")
    }

    func testSettingsWindow() {
        app.typeKey(",", modifierFlags: .command)

        let generalTab = app.buttons["General"]
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5))

        let modelsTab = app.buttons["Models"]
        XCTAssertTrue(modelsTab.waitForExistence(timeout: 5))

        let toolsTab = app.buttons["Tools"]
        XCTAssertTrue(toolsTab.waitForExistence(timeout: 5))
    }

    func testConversationSwitching() {
        composeInitialMessageAndSend("Topic Alpha")
        let sidebarList = app.outlines[TestIdentifiers.Sidebar.conversationList]
        XCTAssertTrue(sidebarList.staticTexts["Topic Alpha"].waitForExistence(timeout: 5))

        let newButton = app.buttons[TestIdentifiers.Sidebar.newConversationButton].firstMatch
        newButton.click()

        let composer = app.textViews[TestIdentifiers.NewChatComposer.textEditor]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        composer.click()
        let hasFocus = NSPredicate(format: "hasKeyboardFocus == true")
        let focusExpectation = XCTNSPredicateExpectation(predicate: hasFocus, object: composer)
        let focusWaitResult = XCTWaiter.wait(for: [focusExpectation], timeout: 5)
        XCTAssertEqual(focusWaitResult, .completed)

        composer.typeText("Topic Beta")
        app.buttons[TestIdentifiers.NewChatComposer.sendButton].click()

        XCTAssertTrue(sidebarList.staticTexts["Topic Beta"].waitForExistence(timeout: 5))

        let alphaRow = sidebarList.staticTexts["Topic Alpha"]
        alphaRow.click()

        let messagesList = app.scrollViews[TestIdentifiers.ChatView.messagesList]
        XCTAssertTrue(messagesList.waitForExistence(timeout: 5), "Chat messages list should be visible")

        let alphaMessage = messagesList.descendants(matching: .any).containing(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.", "Topic Alpha")
        ).firstMatch
        XCTAssertTrue(
            alphaMessage.waitForExistence(timeout: 5),
            "Active conversation message should appear in the chat messages list"
        )

        let betaMessages = messagesList.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "chat.message.", "Topic Beta")
        )
        let betaAbsent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 0"),
            object: betaMessages
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [betaAbsent], timeout: 5),
            .completed,
            "Inactive conversation messages should not appear in the chat messages list"
        )
    }

    func testMessageCopy() {
        composeInitialMessageAndSend("Text to copy")

        let responseText = "UI Test Response: Text to copy"
        let responsePredicate = NSPredicate(format: "label CONTAINS %@", responseText)

        let messageBubble = app.otherElements.containing(responsePredicate).firstMatch
        XCTAssertTrue(messageBubble.waitForExistence(timeout: 10))

        messageBubble.rightClick()

        let copyMenuItem = app.menuItems["Copy"]
        XCTAssertTrue(copyMenuItem.waitForExistence(timeout: 2))
    }

    func testChatPromptAutoFocusOnLaunchAndAfterSend() {
        let newChatComposer = app.textViews[TestIdentifiers.NewChatComposer.textEditor]
        XCTAssertTrue(newChatComposer.waitForExistence(timeout: 5))
        assertHasKeyboardFocus(newChatComposer)

        let message = "Focus test message"
        newChatComposer.typeText(message)

        let sendButton = app.buttons[TestIdentifiers.NewChatComposer.sendButton]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 5))
        sendButton.click()

        let chatComposer = app.textViews[TestIdentifiers.ChatComposer.textEditor]
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 10))
        assertHasKeyboardFocus(chatComposer)
    }

    @discardableResult
    private func composeInitialMessageAndSend(_ text: String) -> XCUIElement {
        let composer = ensureNewConversationComposer()
        composer.click()

        let hasFocus = NSPredicate(format: "hasKeyboardFocus == true")
        let focusExpectation = XCTNSPredicateExpectation(predicate: hasFocus, object: composer)
        let composeFocusResult = XCTWaiter.wait(for: [focusExpectation], timeout: 5)
        XCTAssertEqual(composeFocusResult, .completed)

        composer.typeText(text)

        let sendButton = app.buttons[TestIdentifiers.NewChatComposer.sendButton]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        sendButton.click()

        let chatComposer = app.textViews[TestIdentifiers.ChatComposer.textEditor]
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 10))
        return chatComposer
    }

    private func ensureNewConversationComposer() -> XCUIElement {
        let composer = app.textViews[TestIdentifiers.NewChatComposer.textEditor]
        print("Window count: \(app.windows.count)")
        if composer.waitForExistence(timeout: 10) {
            return composer
        }

        print("UI Debug Description:\n\(app.debugDescription)")

        let newConversationButton = app.buttons[TestIdentifiers.Sidebar.newConversationButton]
            .firstMatch
        XCTAssertTrue(newConversationButton.waitForExistence(timeout: 10))
        newConversationButton.click()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        return composer
    }

    private func assertHasKeyboardFocus(
        _ element: XCUIElement,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected element to have keyboard focus", file: file, line: line)
    }
}
