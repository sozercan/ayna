#if os(macOS)
import AppKit
import Foundation
import Testing

@testable import Ayna

@Suite("Syntax Highlight Performance Benchmarks", .tags(.slow), .serialized)
@MainActor
struct SyntaxHighlightPerformanceBenchmarkTests {
    @Test("Large Swift code uses plain fast path", .timeLimit(.minutes(1)))
    func largeSwiftCodeUsesPlainFastPath() {
        let code = Self.swiftFixture(lineCount: 3_000, marker: UUID().uuidString)

        #expect(SyntaxHighlightedCodeView.usesLargeCodeFastPath(code))
        #expect(!SyntaxHighlightedCodeView.isHighlightCached(for: code, language: "swift"))

        let start = CFAbsoluteTimeGetCurrent()
        let highlighted = SyntaxHighlightedCodeView(code: code, language: "swift").highlightedCode()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        print("BENCH syntax.swift.large.fastPath bytes=\(code.utf8.count) seconds=\(elapsed)")
        #expect(String(highlighted.characters) == code)
        #expect(Self.foregroundColorDescriptions(in: highlighted).count == 1)
        #expect(SyntaxHighlightedCodeView.isHighlightCached(for: code, language: "swift"))
    }

    @Test("Medium Swift code keeps highlighting and caches", .timeLimit(.minutes(1)))
    func mediumSwiftCodeKeepsHighlightingAndCaches() {
        let code = Self.swiftFixture(lineCount: 320, marker: UUID().uuidString)

        #expect(code.utf8.count < SyntaxHighlightedCodeView.largeCodeFastPathByteLimit)
        #expect(!SyntaxHighlightedCodeView.usesLargeCodeFastPath(code))
        #expect(!SyntaxHighlightedCodeView.isHighlightCached(for: code, language: "swift"))

        let firstStart = CFAbsoluteTimeGetCurrent()
        let first = SyntaxHighlightedCodeView(code: code, language: "swift").highlightedCode()
        let firstElapsed = CFAbsoluteTimeGetCurrent() - firstStart

        #expect(SyntaxHighlightedCodeView.isHighlightCached(for: code, language: "swift"))

        let secondStart = CFAbsoluteTimeGetCurrent()
        let second = SyntaxHighlightedCodeView(code: code, language: "swift").highlightedCode()
        let secondElapsed = CFAbsoluteTimeGetCurrent() - secondStart

        print(
            "BENCH syntax.swift.medium.cached bytes=\(code.utf8.count) firstSeconds=\(firstElapsed) secondSeconds=\(secondElapsed)"
        )
        #expect(String(first.characters) == code)
        #expect(String(second.characters) == code)
        #expect(Self.foregroundColorDescriptions(in: first).count > 1)
        #expect(Self.foregroundColorDescriptions(in: second).count > 1)
    }

    private static func swiftFixture(lineCount: Int, marker: String) -> String {
        var lines = ["// benchmark marker \(marker)"]
        lines.reserveCapacity(lineCount + 1)

        for index in 0 ..< lineCount {
            lines.append("func value\(index)() -> Int { let number = \(index); return number + 1 }")
        }

        return lines.joined(separator: "\n")
    }

    private static func foregroundColorDescriptions(in attributedString: AttributedString) -> Set<String> {
        let nsAttributedString = NSAttributedString(attributedString)
        let fullRange = NSRange(location: 0, length: nsAttributedString.length)
        var colors: Set<String> = []

        nsAttributedString.enumerateAttribute(.foregroundColor, in: fullRange) { value, _, _ in
            guard let value else { return }
            colors.insert(String(describing: value))
        }

        return colors
    }
}
#endif
