#if os(watchOS)

    import Foundation
    import SwiftUI

    enum WatchMarkdownRenderer {
        private static let inlineMarkdownOptions: AttributedString.MarkdownParsingOptions = {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            return options
        }()

        private static let linkRegex: NSRegularExpression = {
            let pattern = #"\[([^\]]+)\]\([^\)]+\)"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                preconditionFailure("Invalid static watch markdown regular expression: \(pattern)")
            }
            return expression
        }()

        static func render(_ text: String) -> AttributedString {
            do {
                return try AttributedString(markdown: text, options: inlineMarkdownOptions)
            } catch {
                return AttributedString(text)
            }
        }

        static func renderStyled(_ text: String, isUser: Bool) -> AttributedString {
            var attributed = render(text)

            let baseColor: Color = isUser ? .white : .primary

            for run in attributed.runs {
                let range = run.range
                attributed[range].foregroundColor = baseColor
            }

            return attributed
        }

        static func stripMarkdown(_ text: String) -> String {
            var result = text

            result = result.replacingOccurrences(of: "**", with: "")
            result = result.replacingOccurrences(of: "__", with: "")
            result = result.replacingOccurrences(of: "*", with: "")
            result = result.replacingOccurrences(of: "_", with: "")

            result = result.replacingOccurrences(of: "`", with: "")

            let range = NSRange(result.startIndex..., in: result)
            result = linkRegex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "$1"
            )

            result = result.replacingOccurrences(of: "### ", with: "")
            result = result.replacingOccurrences(of: "## ", with: "")
            result = result.replacingOccurrences(of: "# ", with: "")

            return result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

#endif
