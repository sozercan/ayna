import Testing

@testable import Ayna

@Suite("MarkdownRenderer Tests")
struct MarkdownRendererTests {
    @Test("Parses headings, paragraphs, and divider")
    func parsesHeadingsParagraphsAndDivider() {
        let input = """
        # Title

        Some **bold** text.

        ---

        More text.
        """
        let blocks = MarkdownRenderer.parse(input)
        #expect(blocks.count == 4)
        guard blocks.count == 4 else { return }
        if case let .heading(level, text) = blocks[0].type {
            #expect(level == 1)
            #expect(String(text.characters) == "Title")
        } else {
            Issue.record("Expected heading block")
        }
        if case let .paragraph(text) = blocks[1].type {
            #expect(String(text.characters).contains("bold"))
        } else {
            Issue.record("Expected paragraph block")
        }
        if case .divider = blocks[2].type {
            // success
        } else {
            Issue.record("Expected divider block")
        }
        if case let .paragraph(text) = blocks[3].type {
            #expect(String(text.characters).contains("More text"))
        } else {
            Issue.record("Expected paragraph block")
        }
    }

    @Test("Parses lists and blockquote")
    func parsesListsAndBlockquote() {
        let input = """
        - First
        - Second

        1. Item one
        2. Item two

        > Tip block
        """
        let blocks = MarkdownRenderer.parse(input)
        #expect(blocks.count == 3)
        if case let .unorderedList(items) = blocks[0].type {
            #expect(items.count == 2)
        } else {
            Issue.record("Expected unordered list block")
        }
        if case let .orderedList(start, items) = blocks[1].type {
            #expect(start == 1)
            #expect(items.count == 2)
        } else {
            Issue.record("Expected ordered list block")
        }
        if case let .blockquote(text) = blocks[2].type {
            #expect(String(text.characters) == "Tip block")
        } else {
            Issue.record("Expected blockquote block")
        }
    }

    @Test("Parses code and tool blocks")
    func parsesCodeAndToolBlocks() {
        let input = """
        ```swift
        print("Hello")
        ```

        [Tool: search]
        result
        """
        let blocks = MarkdownRenderer.parse(input)
        #expect(blocks.count == 2)
        if case let .code(code, language) = blocks[0].type {
            #expect(language == "swift")
            #expect(code.contains("print"))
        } else {
            Issue.record("Expected code block")
        }
        if case let .tool(name, result) = blocks[1].type {
            #expect(name == "search")
            #expect(result == "result")
        } else {
            Issue.record("Expected tool block")
        }
    }

    @Test("Parses tables")
    func parsesTables() {
        let input = """
        | Name | Value |
        | ---- | ----: |
        | foo | 1 |
        | bar | 2 |
        """
        let blocks = MarkdownRenderer.parse(input)
        #expect(blocks.count == 1)
        guard case let .table(table) = blocks[0].type else {
            Issue.record("Expected table block")
            return
        }
        #expect(table.headers.count == 2)
        #expect(table.rows.count == 2)
        #expect(table.alignments.count == 2)
        #expect(String(table.headers[0].characters) == "Name")
    }

    @Test("Parses nested code blocks")
    func parsesNestedCodeBlocks() {
        let input = """
        ````markdown
        # Title
        ```javascript
        console.log("hi")
        ```
        ````
        """
        let blocks = MarkdownRenderer.parse(input)
        #expect(blocks.count == 1)
        if case let .code(code, language) = blocks[0].type {
            #expect(language == "markdown")
            #expect(code.contains("# Title"))
            #expect(code.contains("```javascript"))
            #expect(code.contains("console.log"))
            #expect(code.contains("```"))
        } else {
            Issue.record("Expected code block")
        }
    }

    @Test("Parses ambiguous nested markdown block")
    func parsesAmbiguousNestedMarkdownBlock() {
        let content = """
        ```markdown
        # Title
        ```bash
        echo "hello"
        ```
        ## Usage
        ```
        """
        let blocks = MarkdownRenderer.parse(content)
        #expect(blocks.count == 1)
        if case let .code(code, lang) = blocks.first?.type {
            #expect(lang == "markdown")
            #expect(code.contains("## Usage"))
        } else {
            Issue.record("Expected code block")
        }
    }

    @Test("Longer fence closes shorter fence")
    func longerFenceClosesShorterFence() {
        let content = """
        ```
        code
        ````
        """
        let blocks = MarkdownRenderer.parse(content)
        #expect(blocks.count == 1)
        if case let .code(code, _) = blocks.first?.type {
            #expect(code.trimmingCharacters(in: .whitespacesAndNewlines) == "code")
        }
    }
}
