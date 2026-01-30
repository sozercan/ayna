//
//  WatchMarkdownRenderer.swift
//  Ayna Watch App
//
//  Created on 11/29/25.
//

#if os(watchOS)

    import Foundation
    import SwiftUI

    /// Simplified markdown renderer for watchOS
    /// Only handles inline formatting (bold, italic, code, links)
    /// Complex elements like code blocks and tables are rendered as plain text
    enum WatchMarkdownRenderer {
        /// Render markdown string to AttributedString for Watch display
        /// Uses system AttributedString markdown support for inline elements only
        static func render(_ text: String) -> AttributedString {
            // Try to parse as inline markdown
            do {
                var options = AttributedString.MarkdownParsingOptions()
                options.interpretedSyntax = .inlineOnlyPreservingWhitespace
                return try AttributedString(markdown: text, options: options)
            } catch {
                // Fall back to plain text
                return AttributedString(text)
            }
        }

        /// Render markdown with custom styling for Watch
        static func renderStyled(_ text: String, isUser: Bool) -> AttributedString {
            var attributed = render(text)

            // Apply base styling based on message role
            let baseColor: Color = isUser ? .white : .primary

            // Update all runs with the base color
            for run in attributed.runs {
                let range = run.range
                attributed[range].foregroundColor = baseColor
            }

            return attributed
        }

        /// Strip markdown for preview text (used in conversation list)
        static func stripMarkdown(_ text: String) -> String {
            // Simple regex-based stripping for common markdown
            var result = text

            // Remove bold/italic markers
            result = result.replacingOccurrences(of: "**", with: "")
            result = result.replacingOccurrences(of: "__", with: "")
            result = result.replacingOccurrences(of: "*", with: "")
            result = result.replacingOccurrences(of: "_", with: "")

            // Remove inline code
            result = result.replacingOccurrences(of: "`", with: "")

            // Remove link syntax [text](url) -> text
            let linkPattern = #"\[([^\]]+)\]\([^\)]+\)"#
            if let regex = try? NSRegularExpression(pattern: linkPattern) {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: range,
                    withTemplate: "$1"
                )
            }

            // Remove headers
            result = result.replacingOccurrences(of: "### ", with: "")
            result = result.replacingOccurrences(of: "## ", with: "")
            result = result.replacingOccurrences(of: "# ", with: "")

            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

#endif
