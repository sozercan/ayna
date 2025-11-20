@testable import Ayna
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
                "UI Test Response",
            ),
        ).firstMatch

        let foundResponse = responseLabel.waitForExistence(timeout: 10)
            || responseTextView.waitForExistence(timeout: 10)
            || genericResponse.waitForExistence(timeout: 10)
        XCTAssertTrue(foundResponse)

        let chatComposer = app.textViews[TestIdentifiers.ChatComposer.textEditor]
        XCTAssertTrue(chatComposer.waitForExistence(timeout: 10))
        XCTAssertEqual((chatComposer.value as? String) ?? "", "")

        // Title should update from "New Conversation" to the message content
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

        // Title should be the message content
        let title = "Message with \(uniqueKeyword)"
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 10))

        // Create another one
        composeInitialMessageAndSend("Another conversation")
        let otherTitle = "Another conversation"
        XCTAssertTrue(app.staticTexts[otherTitle].waitForExistence(timeout: 10))

        // Search
        let searchField = app.textFields[TestIdentifiers.Sidebar.searchField]
        XCTAssertTrue(searchField.exists)
        searchField.click()
        searchField.typeText(uniqueKeyword)

        // Verify filtering
        XCTAssertTrue(app.staticTexts[title].exists)
        XCTAssertFalse(app.staticTexts[otherTitle].exists)
    }

    func testDeleteConversation() {
        let msg = "Conversation to delete"
        composeInitialMessageAndSend(msg)

        // Wait for sidebar to update
        let sidebarList = app.outlines[TestIdentifiers.Sidebar.conversationList]
        let title = sidebarList.staticTexts[msg]
        XCTAssertTrue(title.waitForExistence(timeout: 10))

        title.rightClick()

        // Context menu item "Delete" (identifier: trash)
        let deleteButton = app.menuItems["trash"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        deleteButton.click()

        // Wait for menu to close
        XCTAssertTrue(deleteButton.waitForNonExistence(timeout: 2))

        // Confirm deletion in alert if present (not present in this app flow, it just deletes)

        // Verify it's gone
        let doesNotExist = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: doesNotExist, object: title)
        // Increased timeout to 10s to account for potential animation or state update delays
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed)
    }

    func testSettingsWindow() {
        // Open Settings via keyboard shortcut (Cmd+,)
        app.typeKey(",", modifierFlags: .command)

        // The settings window usually has the title "Settings" or the app name
        // We look for the toolbar buttons which act as tabs
        let generalTab = app.buttons["General"]
        XCTAssertTrue(generalTab.waitForExistence(timeout: 5))

        let modelsTab = app.buttons["Models"]
        XCTAssertTrue(modelsTab.exists)

        let mcpTab = app.buttons["MCP Tools"]
        XCTAssertTrue(mcpTab.exists)
    }

    func testConversationSwitching() {
        // 1. Create first conversation
        composeInitialMessageAndSend("Topic Alpha")
        let sidebarList = app.outlines[TestIdentifiers.Sidebar.conversationList]
        XCTAssertTrue(sidebarList.staticTexts["Topic Alpha"].waitForExistence(timeout: 5))

        // 2. Create second conversation
        let newButton = app.buttons[TestIdentifiers.Sidebar.newConversationButton].firstMatch
        newButton.click()

        let composer = app.textViews[TestIdentifiers.NewChatComposer.textEditor]
        XCTAssertTrue(composer.waitForExistence(timeout: 5))

        // Ensure focus before typing
        composer.click()
        // Wait for keyboard focus
        let hasFocus = NSPredicate(format: "hasKeyboardFocus == true")
        let focusExpectation = XCTNSPredicateExpectation(predicate: hasFocus, object: composer)
        XCTWaiter.wait(for: [focusExpectation], timeout: 5)

        composer.typeText("Topic Beta")
        app.buttons[TestIdentifiers.NewChatComposer.sendButton].click()

        XCTAssertTrue(sidebarList.staticTexts["Topic Beta"].waitForExistence(timeout: 5))

        // 3. Switch back to Alpha
        // Use sidebar list to find the specific row
        let alphaRow = sidebarList.staticTexts["Topic Alpha"]
        alphaRow.click()

        // 4. Verify Alpha content is present
        // We look for the message content in the chat view.
        // Since "Topic Alpha" is also the title, we look for the message bubble specifically.
        // The message bubble has an accessibility label equal to the content.
        // To be safe, we can check that "Topic Beta" message is NOT present.

        // A more robust way: check for the unique user message text element
        // that is NOT the sidebar element.
        // The sidebar element is usually a static text inside a cell.
        // The message bubble is also a static text (or text view).
        // We can check that we have at least 2 occurrences of "Topic Alpha" (one sidebar, one chat)
        // and only 1 occurrence of "Topic Beta" (sidebar only).

        let alphaTexts = app.staticTexts.matching(identifier: "Topic Alpha")
        // This might not work if identifier isn't set to content.
        // Let's rely on the fact that clicking the sidebar row changes the selection.

        // Let's verify the copy button exists for the current chat, which implies a chat is loaded.
        // And verify the content text exists in the chat area (not sidebar)
        // We can use a predicate to exclude sidebar elements if needed, but simple existence check is a good start.
        // Since we clicked Alpha, we expect to see Alpha message.

        // Wait a bit for switch
        sleep(1)

        // Check for message bubble content
        // User message is an 'Other' element with label == content
        let messageBubble = app.otherElements.containing(
            NSPredicate(format: "label == %@", "Topic Alpha"),
        ).firstMatch
        XCTAssertTrue(messageBubble.waitForExistence(timeout: 5))
    }

    func testMessageCopy() {
        composeInitialMessageAndSend("Text to copy")

        // Wait for response to appear (which also has a copy button)
        let responseText = "UI Test Response: Text to copy"
        let responsePredicate = NSPredicate(format: "label CONTAINS %@", responseText)

        // Find the message container (Other element) that contains this text
        // This is more reliable for hovering than the text itself
        let messageBubble = app.otherElements.containing(responsePredicate).firstMatch
        XCTAssertTrue(messageBubble.waitForExistence(timeout: 10))

        // Hover to reveal buttons
        messageBubble.hover()

        // Wait a moment for animation/state update
        let copyButton = app.buttons["message.action.copy"].firstMatch
        XCTAssertTrue(copyButton.waitForExistence(timeout: 2))
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
        // Use coordinate tap to avoid "unable to find hit point" errors if element is partially obscured
        composer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // Wait for focus
        let hasFocus = NSPredicate(format: "hasKeyboardFocus == true")
        let focusExpectation = XCTNSPredicateExpectation(predicate: hasFocus, object: composer)
        XCTWaiter.wait(for: [focusExpectation], timeout: 5)

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
        line: UInt = #line,
    ) {
        let predicate = NSPredicate(format: "hasKeyboardFocus == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected element to have keyboard focus", file: file, line: line)
    }
}
