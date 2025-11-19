@testable import Ayna
import XCTest

final class MarkdownRendererTests: XCTestCase {
    func testParsesHeadingsParagraphsAndDivider() {
        let input = """
        # Title

        Some **bold** text.

        ---

        More text.
        """
        let blocks = MarkdownRenderer.parse(input)
        XCTAssertEqual(blocks.count, 4)
        guard blocks.count == 4 else { return }
        if case let .heading(level, text) = blocks[0].type {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(String(text.characters), "Title")
        } else {
            XCTFail("Expected heading block")
        }
        if case let .paragraph(text) = blocks[1].type {
            XCTAssertTrue(String(text.characters).contains("bold"))
        } else {
            XCTFail("Expected paragraph block")
        }
        if case .divider = blocks[2].type {
            // success
        } else {
            XCTFail("Expected divider block")
        }
        if case let .paragraph(text) = blocks[3].type {
            XCTAssertTrue(String(text.characters).contains("More text"))
        } else {
            XCTFail("Expected paragraph block")
        }
    }

    func testParsesListsAndBlockquote() {
        let input = """
        - First
        - Second

        1. Item one
        2. Item two

        > Tip block
        """
        let blocks = MarkdownRenderer.parse(input)
        XCTAssertEqual(blocks.count, 3)
        if case let .unorderedList(items) = blocks[0].type {
            XCTAssertEqual(items.count, 2)
        } else {
            XCTFail("Expected unordered list block")
        }
        if case let .orderedList(start, items) = blocks[1].type {
            XCTAssertEqual(start, 1)
            XCTAssertEqual(items.count, 2)
        } else {
            XCTFail("Expected ordered list block")
        }
        if case let .blockquote(text) = blocks[2].type {
            XCTAssertEqual(String(text.characters), "Tip block")
        } else {
            XCTFail("Expected blockquote block")
        }
    }

    func testParsesCodeAndToolBlocks() {
        let input = """
        ```swift
        print("Hello")
        ```

        [Tool: search]
        result
        """
        let blocks = MarkdownRenderer.parse(input)
        XCTAssertEqual(blocks.count, 2)
        if case let .code(code, language) = blocks[0].type {
            XCTAssertEqual(language, "swift")
            XCTAssertTrue(code.contains("print"))
        } else {
            XCTFail("Expected code block")
        }
        if case let .tool(name, result) = blocks[1].type {
            XCTAssertEqual(name, "search")
            XCTAssertEqual(result, "result")
        } else {
            XCTFail("Expected tool block")
        }
    }

    func testParsesTables() {
        let input = """
        | Name | Value |
        | ---- | ----: |
        | foo | 1 |
        | bar | 2 |
        """
        let blocks = MarkdownRenderer.parse(input)
        XCTAssertEqual(blocks.count, 1)
        guard case let .table(table) = blocks[0].type else {
            return XCTFail("Expected table block")
        }
        XCTAssertEqual(table.headers.count, 2)
        XCTAssertEqual(table.rows.count, 2)
        XCTAssertEqual(table.alignments.count, 2)
        XCTAssertEqual(String(table.headers[0].characters), "Name")
    }

    func testParsesNestedCodeBlocks() {
        let input = """
        ````markdown
        # Title
        ```javascript
        console.log("hi")
        ```
        ````
        """
        let blocks = MarkdownRenderer.parse(input)
        XCTAssertEqual(blocks.count, 1)
        if case let .code(code, language) = blocks[0].type {
            XCTAssertEqual(language, "markdown")
            XCTAssertTrue(code.contains("# Title"))
            XCTAssertTrue(code.contains("```javascript"))
            XCTAssertTrue(code.contains("console.log"))
            XCTAssertTrue(code.contains("```"))
        } else {
            XCTFail("Expected code block")
        }
    }

    func testParsesAmbiguousNestedMarkdownBlock() {
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
        XCTAssertEqual(blocks.count, 1)
        if case .code(let code, let lang) = blocks.first?.type {
            XCTAssertEqual(lang, "markdown")
            XCTAssertTrue(code.contains("## Usage"))
        } else {
            XCTFail("Expected code block")
        }
    }

    func testLongerFenceClosesShorterFence() {
        let content = """
        ```
        code
        ````
        """
        let blocks = MarkdownRenderer.parse(content)
        XCTAssertEqual(blocks.count, 1)
        if case .code(let code, _) = blocks.first?.type {
            XCTAssertEqual(code.trimmingCharacters(in: .whitespacesAndNewlines), "code")
        }
    }
}
