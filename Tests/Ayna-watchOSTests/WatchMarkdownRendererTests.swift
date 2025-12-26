//
//  WatchMarkdownRendererTests.swift
//  Ayna-watchOSTests
//
//  Unit tests for WatchMarkdownRenderer on watchOS
//

@testable import Ayna_watchOS_Watch_App
import Foundation
import Testing

@Suite("WatchMarkdownRenderer Tests")
struct WatchMarkdownRendererTests {
    // MARK: - Basic Rendering Tests

    @Test("Render plain text")
    func renderPlainText() {
        let text = "Hello, World!"
        let result = WatchMarkdownRenderer.render(text)

        #expect(String(result.characters) == text)
    }

    @Test("Render bold text")
    func renderBoldText() {
        let text = "Hello **bold** world"
        let result = WatchMarkdownRenderer.render(text)

        // The AttributedString should contain the text with bold formatting
        #expect(String(result.characters).contains("bold"))
    }

    @Test("Render italic text")
    func renderItalicText() {
        let text = "Hello *italic* world"
        let result = WatchMarkdownRenderer.render(text)

        #expect(String(result.characters).contains("italic"))
    }

    @Test("Render inline code")
    func renderInlineCode() {
        let text = "Use `code` here"
        let result = WatchMarkdownRenderer.render(text)

        #expect(String(result.characters).contains("code"))
    }

    @Test("Render mixed formatting")
    func renderMixedFormatting() {
        let text = "**Bold** and *italic* and `code`"
        let result = WatchMarkdownRenderer.render(text)

        let chars = String(result.characters)
        #expect(chars.contains("Bold"))
        #expect(chars.contains("italic"))
        #expect(chars.contains("code"))
    }

    // MARK: - Styled Rendering Tests

    @Test("Render styled user message")
    func renderStyledUserMessage() {
        let text = "Hello from user"
        let result = WatchMarkdownRenderer.renderStyled(text, isUser: true)

        #expect(String(result.characters) == text)
    }

    @Test("Render styled assistant message")
    func renderStyledAssistantMessage() {
        let text = "Hello from assistant"
        let result = WatchMarkdownRenderer.renderStyled(text, isUser: false)

        #expect(String(result.characters) == text)
    }

    // MARK: - Strip Markdown Tests

    @Test("Strip markdown bold")
    func stripMarkdownBold() {
        let text = "Hello **bold** world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result == "Hello bold world")
    }

    @Test("Strip markdown italic")
    func stripMarkdownItalic() {
        let text = "Hello *italic* world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result == "Hello italic world")
    }

    @Test("Strip markdown inline code")
    func stripMarkdownInlineCode() {
        let text = "Use `code` here"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result == "Use code here")
    }

    @Test("Strip markdown links")
    func stripMarkdownLinks() {
        let text = "Check [this link](https://example.com) out"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result == "Check this link out")
    }

    @Test("Strip markdown headers")
    func stripMarkdownHeaders() {
        let h1 = "# Header 1"
        let h2 = "## Header 2"
        let h3 = "### Header 3"

        #expect(WatchMarkdownRenderer.stripMarkdown(h1) == "Header 1")
        #expect(WatchMarkdownRenderer.stripMarkdown(h2) == "Header 2")
        #expect(WatchMarkdownRenderer.stripMarkdown(h3) == "Header 3")
    }

    @Test("Strip markdown mixed")
    func stripMarkdownMixed() {
        let text = "# Title\n**Bold** and [link](url)"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result.contains("Title"))
        #expect(result.contains("Bold"))
        #expect(result.contains("link"))
        #expect(!result.contains("**"))
        #expect(!result.contains("["))
        #expect(!result.contains("]("))
    }

    @Test("Strip markdown empty string")
    func stripMarkdownEmptyString() {
        let result = WatchMarkdownRenderer.stripMarkdown("")
        #expect(result == "")
    }

    @Test("Strip markdown whitespace")
    func stripMarkdownWhitespace() {
        let text = "  **bold**  "
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result == "bold")
    }

    // MARK: - Edge Cases

    @Test("Render empty string")
    func renderEmptyString() {
        let result = WatchMarkdownRenderer.render("")
        #expect(String(result.characters) == "")
    }

    @Test("Render special characters")
    func renderSpecialCharacters() {
        let text = "Hello & < > \" ' characters"
        let result = WatchMarkdownRenderer.render(text)

        // Should handle special characters gracefully
        #expect(!String(result.characters).isEmpty)
    }

    @Test("Render long text")
    func renderLongText() {
        let text = String(repeating: "This is a long text. ", count: 100)
        let result = WatchMarkdownRenderer.render(text)

        #expect(String(result.characters) == text)
    }

    @Test("Strip markdown underscore bold")
    func stripMarkdownUnderscoreBold() {
        let text = "Hello __bold__ world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result == "Hello bold world")
    }

    @Test("Strip markdown underscore italic")
    func stripMarkdownUnderscoreItalic() {
        let text = "Hello _italic_ world"
        let result = WatchMarkdownRenderer.stripMarkdown(text)

        #expect(result == "Hello italic world")
    }
}
