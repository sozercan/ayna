import Foundation
import SwiftUI

/// Converts markdown text into renderable content blocks tailored for the chat UI.
enum MarkdownRenderer {
    // Cache for parsed content blocks to improve performance
    // Configured with limits to prevent unbounded memory growth
    private nonisolated(unsafe) static let cache: NSCache<NSString, ContentBlockWrapper> = {
        let cache = NSCache<NSString, ContentBlockWrapper>()
        cache.countLimit = 100 // Maximum 100 cached markdown parses
        return cache
    }()

    private class ContentBlockWrapper {
        let blocks: [ContentBlock]
        init(blocks: [ContentBlock]) {
            self.blocks = blocks
        }
    }

    static func parse(_ content: String) -> [ContentBlock] {
        var blocks: [ContentBlock] = []

        // Check cache first
        let cacheKey = content as NSString
        if let cachedWrapper = cache.object(forKey: cacheKey) {
            return cachedWrapper.blocks
        }

        let lines = content.components(separatedBy: .newlines)
        var index = 0
        var paragraphBuffer: [String] = []
        var pendingToolName: String?
        var pendingToolResult = ""

        func flushParagraph() {
            guard paragraphBuffer.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            else {
                paragraphBuffer.removeAll()
                return
            }
            let paragraphText = paragraphBuffer.joined(separator: "\n")
            let trimmedParagraph = paragraphText.trimmingCharacters(in: .newlines)
            let attributed = MarkdownRenderer.makeInlineAttributedString(from: trimmedParagraph)
            blocks.append(ContentBlock(type: .paragraph(attributed)))
            paragraphBuffer.removeAll()
        }

        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let toolName = pendingToolName {
                if trimmed.isEmpty {
                    let result = pendingToolResult.trimmingCharacters(in: .newlines)
                    blocks.append(ContentBlock(type: .tool(toolName, result)))
                    pendingToolName = nil
                    pendingToolResult = ""
                } else {
                    pendingToolResult += line + "\n"
                }
                index += 1
                continue
            }

            if trimmed.hasPrefix("[Tool:"), trimmed.hasSuffix("]"),
               let toolName = extractToolName(from: trimmed)
            {
                flushParagraph()
                pendingToolName = toolName
                pendingToolResult = ""
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let backtickCount = trimmed.prefix(while: { $0 == "`" }).count
                if backtickCount >= 3 {
                    flushParagraph()
                    let block = parseCodeBlock(
                        lines: lines,
                        index: &index,
                        backtickCount: backtickCount,
                        trimmedHeader: trimmed
                    )
                    blocks.append(block)
                    continue
                }
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let headingLevel = headingLevel(for: trimmed) {
                flushParagraph()
                let textStart = trimmed.index(trimmed.startIndex, offsetBy: headingLevel)
                let headingText = trimmed[textStart...].trimmingCharacters(in: .whitespaces)
                let attributed = MarkdownRenderer.makeInlineAttributedString(from: headingText)
                blocks.append(ContentBlock(type: .heading(level: headingLevel, text: attributed)))
                index += 1
                continue
            }

            if let tableResult = parseTable(from: lines, startingAt: index) {
                flushParagraph()
                blocks.append(ContentBlock(type: .table(tableResult.table)))
                index = tableResult.nextIndex
                continue
            }

            if let quoteResult = parseBlockquote(from: lines, startingAt: index) {
                flushParagraph()
                blocks.append(ContentBlock(type: .blockquote(quoteResult.attributed)))
                index = quoteResult.nextIndex
                continue
            }

            if let listResult = parseList(from: lines, startingAt: index) {
                flushParagraph()
                blocks.append(listResult.block)
                index = listResult.nextIndex
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(ContentBlock(type: .divider))
                index += 1
                continue
            }

            paragraphBuffer.append(line)
            index += 1
        }

        flushParagraph()
        if let toolName = pendingToolName {
            let result = pendingToolResult.trimmingCharacters(in: .newlines)
            blocks.append(ContentBlock(type: .tool(toolName, result)))
        }

        // Update cache
        cache.setObject(ContentBlockWrapper(blocks: blocks), forKey: cacheKey)

        return blocks
    }

    private static func parseCodeBlock(
        lines: [String],
        index: inout Int,
        backtickCount: Int,
        trimmedHeader: String
    ) -> ContentBlock {
        let language = trimmedHeader.dropFirst(backtickCount).trimmingCharacters(in: .whitespaces)
        let fence = String(repeating: "`", count: backtickCount)
        var codeLines: [String] = []
        index += 1
        var closed = false

        // Heuristic: If language is markdown, we track nested depth to support
        // nested code blocks even if the LLM uses the same number of backticks.
        let isMarkdown = language.lowercased() == "markdown" || language.lowercased() == "md"
        var nestedDepth = 0

        while index < lines.count {
            let codeLine = lines[index]
            let codeTrimmed = codeLine.trimmingCharacters(in: .whitespaces)

            // Check for closing fence:
            // 1. Must start with backticks
            // 2. Must have at least backtickCount backticks
            // 3. Must consist ONLY of backticks (no info string allowed on closing fence)
            let lineBackticks = codeTrimmed.prefix(while: { $0 == "`" }).count
            let isClosingFence =
                lineBackticks >= backtickCount && codeTrimmed.count == lineBackticks

            if isClosingFence {
                if isMarkdown, nestedDepth > 0 {
                    // It's a closing fence for a nested block
                    nestedDepth -= 1
                    codeLines.append(codeLine)
                    index += 1
                    continue
                } else {
                    // It's the closing fence for our block
                    closed = true
                    index += 1
                    break
                }
            }

            // Check for nested opening fence (only if isMarkdown)
            // If it starts with fence and has content after (language), it's an opening fence.
            if isMarkdown {
                if codeTrimmed.hasPrefix(fence) {
                    let after = codeTrimmed.dropFirst(backtickCount).trimmingCharacters(
                        in: .whitespaces)
                    if !after.isEmpty {
                        nestedDepth += 1
                    }
                }
            }

            codeLines.append(codeLine)
            index += 1
        }

        let code = codeLines.joined(separator: "\n")
        return ContentBlock(type: .code(code, language))
    }

    private static func extractToolName(from line: String) -> String? {
        guard let start = line.firstIndex(of: ":"), let end = line.lastIndex(of: "]") else {
            return nil
        }
        let nameStart = line.index(after: start)
        let raw = line[nameStart ..< end]
        return raw.trimmingCharacters(in: .whitespaces)
    }

    private static func headingLevel(for line: String) -> Int? {
        let level = line.prefix { $0 == "#" }.count
        return level > 0 && level <= 6 && line.count > level ? level : nil
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        if line.count < 3 { return false }
        let allowed = CharacterSet(charactersIn: "-_* ")
        return line.trimmingCharacters(in: allowed).isEmpty
            && line.replacingOccurrences(of: " ", with: "").count >= 3
    }

    private static func parseBlockquote(from lines: [String], startingAt index: Int) -> (
        attributed: AttributedString, nextIndex: Int
    )? {
        var collected: [String] = []
        var current = index
        while current < lines.count {
            let line = lines[current]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            var content = trimmed.dropFirst()
            if content.first == " " {
                content = content.dropFirst()
            }
            collected.append(String(content).trimmingCharacters(in: .whitespaces))
            current += 1
        }
        guard !collected.isEmpty else { return nil }
        let text = collected.joined(separator: "\n")
        let attributed = makeInlineAttributedString(from: text)
        return (attributed, current)
    }

    private static func parseList(from lines: [String], startingAt index: Int) -> (
        block: ContentBlock, nextIndex: Int
    )? {
        var items: [AttributedString] = []
        var current = index
        var ordered = true
        var startIndex = 1

        func listItem(from line: String) -> String? {
            if let range = line.range(of: "^\\s*[-*+]\\s+", options: .regularExpression) {
                ordered = false
                return String(line[range.upperBound...])
            } else if let range = line.range(of: "^\\s*(\\d+)\\.\\s+", options: .regularExpression) {
                ordered = true
                let prefix = line[..<range.upperBound]
                if let number = Int(prefix.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) {
                    if items.isEmpty {
                        startIndex = number
                    }
                }
                return String(line[range.upperBound...])
            }
            return nil
        }

        while current < lines.count {
            let line = lines[current]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            guard let itemText = listItem(from: line) else { break }
            let attributed = makeInlineAttributedString(from: itemText)
            items.append(attributed)
            current += 1
        }

        guard !items.isEmpty else { return nil }
        let blockType: ContentBlock.BlockType =
            ordered ? .orderedList(start: startIndex, items: items) : .unorderedList(items)
        return (ContentBlock(type: blockType), current)
    }

    private static func parseTable(from lines: [String], startingAt index: Int) -> (
        table: MarkdownTable, nextIndex: Int
    )? {
        guard index + 1 < lines.count else { return nil }
        let headerLine = lines[index]
        let dividerLine = lines[index + 1]
        guard headerLine.contains("|"), dividerLine.contains("|") else { return nil }
        let headerCells = splitTableLine(headerLine)
        let dividerCells = splitTableLine(dividerLine)
        guard headerCells.count == dividerCells.count else { return nil }
        guard
            dividerCells.allSatisfy({
                $0.range(of: "^\\s*:?-+:?\\s*$", options: .regularExpression) != nil
            })
        else { return nil }

        let alignments: [MarkdownTable.ColumnAlignment] = dividerCells.map { cell in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") {
                return .center
            } else if trimmed.hasSuffix(":") {
                return .trailing
            } else if trimmed.hasPrefix(":") {
                return .leading
            }
            return .leading
        }

        let headers = headerCells.map {
            makeInlineAttributedString(from: $0.trimmingCharacters(in: .whitespaces))
        }
        var rows: [[AttributedString]] = []
        var current = index + 2
        while current < lines.count {
            let candidate = lines[current]
            if !candidate.contains("|") {
                break
            }
            let rowCells = splitTableLine(candidate)
            if rowCells.count != headers.count {
                break
            }
            let attributedRow = rowCells.map {
                makeInlineAttributedString(from: $0.trimmingCharacters(in: .whitespaces))
            }
            rows.append(attributedRow)
            current += 1
        }

        guard !rows.isEmpty else { return nil }
        let table = MarkdownTable(headers: headers, rows: rows, alignments: alignments)
        return (table, current)
    }

    private static func splitTableLine(_ line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var iterator = line.trimmingCharacters(in: .whitespaces)
        if iterator.hasPrefix("|") { iterator.removeFirst() }
        if iterator.hasSuffix("|") { iterator.removeLast() }
        for char in iterator {
            if char == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        cells.append(current)
        return cells
    }

    private static func makeInlineAttributedString(from markdown: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}

struct MarkdownTable {
    enum ColumnAlignment {
        case leading
        case center
        case trailing
    }

    let headers: [AttributedString]
    let rows: [[AttributedString]]
    let alignments: [ColumnAlignment]
}
