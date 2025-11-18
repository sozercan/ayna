import XCTest
@testable import Ayna

final class AynaSmokeUITests: AynaUITestCase {
  func testConversationCreationShowsMockResponse() {
    composeInitialMessageAndSend("Hello UI Tests")

    let responsePredicate = NSPredicate(format: "label CONTAINS %@", "UI Test Response")
    let responseLabel = app.staticTexts.containing(responsePredicate).firstMatch
    let textViewPredicate = NSPredicate(format: "value CONTAINS %@", "UI Test Response")
    let responseTextView = app.textViews.containing(textViewPredicate).firstMatch
    let genericResponse = app.otherElements.element(matching: NSPredicate(
      format: "label CONTAINS %@ OR value CONTAINS %@",
      "UI Test Response",
      "UI Test Response"
    ))
    let foundResponse = responseLabel.waitForExistence(timeout: 2)
      || responseTextView.waitForExistence(timeout: 3)
      || genericResponse.waitForExistence(timeout: 3)
    XCTAssertTrue(foundResponse)

    let chatComposer = app.textViews[TestIdentifiers.ChatComposer.textEditor]
    XCTAssertTrue(chatComposer.waitForExistence(timeout: 2))
    XCTAssertEqual((chatComposer.value as? String) ?? "", "")

    let conversationTitle = app.staticTexts["New Conversation"]
    XCTAssertTrue(conversationTitle.waitForExistence(timeout: 5))
  }

  func testNewConversationButtonResetsComposer() {
    composeInitialMessageAndSend("First chat")

    let newConversationButton = app.buttons[TestIdentifiers.Sidebar.newConversationButton]
    XCTAssertTrue(newConversationButton.waitForExistence(timeout: 2))
    newConversationButton.click()

    let composer = app.textViews[TestIdentifiers.NewChatComposer.textEditor]
    XCTAssertTrue(composer.waitForExistence(timeout: 2))
    XCTAssertEqual((composer.value as? String) ?? "", "")
  }

  @discardableResult
  private func composeInitialMessageAndSend(_ text: String) -> XCUIElement {
    let composer = ensureNewConversationComposer()
    composer.click()
    composer.typeText(text)

    let sendButton = app.buttons[TestIdentifiers.NewChatComposer.sendButton]
    XCTAssertTrue(sendButton.waitForExistence(timeout: 2))
    sendButton.click()

    let chatComposer = app.textViews[TestIdentifiers.ChatComposer.textEditor]
    XCTAssertTrue(chatComposer.waitForExistence(timeout: 5))
    return chatComposer
  }

  private func ensureNewConversationComposer() -> XCUIElement {
    let composer = app.textViews[TestIdentifiers.NewChatComposer.textEditor]
    if composer.waitForExistence(timeout: 1) {
      return composer
    }

    let newConversationButton = app.buttons[TestIdentifiers.Sidebar.newConversationButton]
    XCTAssertTrue(newConversationButton.waitForExistence(timeout: 2))
    newConversationButton.click()
    XCTAssertTrue(composer.waitForExistence(timeout: 2))
    return composer
  }
}
