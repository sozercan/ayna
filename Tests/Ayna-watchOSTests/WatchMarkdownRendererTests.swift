//
//  WatchMarkdownRendererTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for WatchMarkdownRenderer on watchOS
//

@testable import Ayna_watchOS_Watch_App
import XCTest

final class WatchMarkdownRendererTests: XCTestCase {
    // MARK: - Basic Rendering Tests

    func testRenderPlainText() {
        let text = "Hello, World!"
        let result = WatchMarkdownRenderer.render(text)

        XCTAssertEqual(String(result.characters), text)
    }

    func testRenderBoldText() {
        let text = "Hello **bold** world"
        let result = WatchMarkdownRenderer.render(text)

        // The AttributedString should contain the text with bold formatting
        XCTAssertTrue(String(result.characters).contains("bold"))
    }

    func testRenderItalicText() {
        let text = "Hello *italic* world"
        let result = WatchMarkdownRenderer.render(text)

        XCTAssertTrue(String(result.characters).contains("italic"))
    }

    func testRenderInlineCode() {
        let text = "Use `code` here"
        let result = WatchMarkdownRenderer.render(text)

        XCTAssertTrue(String(result.characters).contains("code"))
    }

    func testRenderMixedFormatting() {
        let text = "**Bold** and *italic* and `code`"
        let result = WatchMarkdownRenderer.render(text)

        let chars = String(result.characters)
        XCTAssertTrue(chars.contains("Bold"))
        XCTAssertTrue(chars.contains("italic"))
        XCTAssertTrue(chars.contains("code"))
    }

    // MARK: - Styled Rendering Tests

    func testRenderStyledUserMessage() {
        let text = "Hello from user"
        let result = WatchMarkdownRenderer.renderStyled(text, isUser: true)

        XCTAssertEqual(String(result.characters), text)
    }

    func testRenderStyledAssistantMessage() {
        let text = "Hello from assistant"
        let result = WatchMarkdownRenderer.renderStyled(text, isUser: false)

        XCTAssertEqual(String(result.characters), text)
    }

    // MARK: - Strip Markdown Tests

    func testStripMarkdownBold() {
        let text = "Hello **bold** world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertEqual(result, "Hello bold world")
    }

    func testStripMarkdownItalic() {
        let text = "Hello *italic* world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertEqual(result, "Hello italic world")
    }

    func testStripMarkdownInlineCode() {
        let text = "Use `code` here"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertEqual(result, "Use code here")
    }

    func testStripMarkdownLinks() {
        let text = "Check [this link](https://example.com) out"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertEqual(result, "Check this link out")
    }

    func testStripMarkdownHeaders() {
        let h1 = "# Header 1"
        let h2 = "## Header 2"
        let h3 = "### Header 3"

        XCTAssertEqual(WatchMarkdownRenderer.stripMarkdown(h1), "Header 1")
        XCTAssertEqual(WatchMarkdownRenderer.stripMarkdown(h2), "Header 2")
        XCTAssertEqual(WatchMarkdownRenderer.stripMarkdown(h3), "Header 3")
    }

    func testStripMarkdownMixed() {
        let text = "# Title\n**Bold** and [link](url)"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertTrue(result.contains("Title"))
        XCTAssertTrue(result.contains("Bold"))
        XCTAssertTrue(result.contains("link"))
        XCTAssertFalse(result.contains("**"))
        XCTAssertFalse(result.contains("["))
        XCTAssertFalse(result.contains("]("))
    }

    func testStripMarkdownEmptyString() {
        let result = WatchMarkdownRenderer.stripMarkdown("")
        XCTAssertEqual(result, "")
    }

    func testStripMarkdownWhitespace() {
        let text = "  **bold**  "
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertEqual(result, "bold")
    }

    // MARK: - Edge Cases

    func testRenderEmptyString() {
        let result = WatchMarkdownRenderer.render("")
        XCTAssertEqual(String(result.characters), "")
    }

    func testRenderSpecialCharacters() {
        let text = "Hello & < > \" ' characters"
        let result = WatchMarkdownRenderer.render(text)

        // Should handle special characters gracefully
        XCTAssertFalse(String(result.characters).isEmpty)
    }

    func testRenderLongText() {
        let text = String(repeating: "This is a long text. ", count: 100)
        let result = WatchMarkdownRenderer.render(text)

        XCTAssertEqual(String(result.characters), text)
    }

    func testStripMarkdownUnderscoreBold() {
        let text = "Hello __bold__ world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertEqual(result, "Hello bold world")
    }

    func testStripMarkdownUnderscoreItalic() {
        let text = "Hello _italic_ world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        XCTAssertEqual(result, "Hello italic world")
    }
}
