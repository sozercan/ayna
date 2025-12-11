//
//  AppContentTests.swift
//  aynaTests
//
//  Tests for AppContent model and related types
//

#if os(macOS)
    @testable import Ayna
    import XCTest

    final class AppContentTests: XCTestCase {
        // MARK: - AppContent Tests

        func testTruncationShortContent() {
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: "com.test",
                windowTitle: "Test Window",
                content: "Short content",
                contentType: .generic,
                isTruncated: false,
                originalLength: 13
            )

            let truncated = content.truncated(to: 100)

            XCTAssertEqual(truncated.content, "Short content")
            XCTAssertFalse(truncated.isTruncated)
        }

        func testTruncationLongContent() {
            let longContent = String(repeating: "a", count: 5000)
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: "com.test",
                windowTitle: nil,
                content: longContent,
                contentType: .documentContent,
                isTruncated: false,
                originalLength: 5000
            )

            let truncated = content.truncated(to: 100)

            XCTAssertTrue(truncated.isTruncated)
            XCTAssertTrue(truncated.content.contains("[Content truncated"))
            XCTAssertLessThan(truncated.content.count, 5000)
        }

        func testTruncationWithoutIndicator() {
            let longContent = String(repeating: "b", count: 200)
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                content: longContent,
                contentType: .terminalOutput,
                isTruncated: false,
                originalLength: 200
            )

            let truncated = content.truncated(to: 50, addIndicator: false)

            XCTAssertTrue(truncated.isTruncated)
            XCTAssertEqual(truncated.content.count, 50)
            XCTAssertFalse(truncated.content.contains("[Content truncated"))
            // Terminal content should keep the END (suffix)
            XCTAssertTrue(truncated.content.hasSuffix(String(repeating: "b", count: 50)))
        }

        func testTerminalTruncationKeepsEnd() {
            // Terminal with distinct start and end content
            let terminalContent = "START_MARKER" + String(repeating: "x", count: 200) + "END_MARKER"
            let content = AppContent(
                appName: "Terminal",
                appIcon: nil,
                bundleIdentifier: "com.apple.Terminal",
                windowTitle: nil,
                content: terminalContent,
                contentType: .terminalOutput,
                isTruncated: false,
                originalLength: terminalContent.count
            )

            let truncated = content.truncated(to: 50, addIndicator: false)

            // Should keep the END, not the START
            XCTAssertTrue(truncated.content.contains("END_MARKER"))
            XCTAssertFalse(truncated.content.contains("START_MARKER"))
        }

        func testDocumentTruncationKeepsStart() {
            // Document with distinct start and end content
            let docContent = "START_MARKER" + String(repeating: "x", count: 200) + "END_MARKER"
            let content = AppContent(
                appName: "Editor",
                appIcon: nil,
                bundleIdentifier: "com.microsoft.VSCode",
                windowTitle: nil,
                content: docContent,
                contentType: .documentContent,
                isTruncated: false,
                originalLength: docContent.count
            )

            let truncated = content.truncated(to: 50, addIndicator: false)

            // Should keep the START, not the END
            XCTAssertTrue(truncated.content.contains("START_MARKER"))
            XCTAssertFalse(truncated.content.contains("END_MARKER"))
        }

        func testForModelLimit() {
            let veryLongContent = String(repeating: "c", count: 20000)
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                content: veryLongContent,
                contentType: .selectedText,
                isTruncated: false,
                originalLength: 20000
            )

            let forModel = content.forModel

            // Should be truncated to model limit (16000) plus indicator
            XCTAssertTrue(forModel.isTruncated)
            XCTAssertTrue(forModel.content.hasPrefix(String(repeating: "c", count: 100)))
            // Total should be around 16000 + indicator text length
            XCTAssertLessThan(forModel.content.count, 17000)
        }

        func testForPreviewLimit() {
            let longContent = String(repeating: "d", count: 1000)
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                content: longContent,
                contentType: .browserURL,
                isTruncated: false,
                originalLength: 1000
            )

            let forPreview = content.forPreview

            // Should be truncated to preview limit (500) plus indicator
            XCTAssertTrue(forPreview.isTruncated)
        }

        // MARK: - Secret Redaction Tests

        func testRedactOpenAIKey() {
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                content: "API_KEY=sk-proj-1234567890123456789012345678901234567890",
                contentType: .terminalOutput,
                isTruncated: false,
                originalLength: 60
            )

            let redacted = content.redacted

            XCTAssertTrue(redacted.content.contains("[REDACTED]"))
            XCTAssertFalse(redacted.content.contains("sk-proj"))
        }

        func testRedactGitHubToken() {
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                content: "token=ghp_123456789012345678901234567890123456",
                contentType: .selectedText,
                isTruncated: false,
                originalLength: 50
            )

            let redacted = content.redacted

            XCTAssertTrue(redacted.content.contains("[REDACTED]"))
            XCTAssertFalse(redacted.content.contains("ghp_"))
        }

        func testRedactBearerToken() {
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                content: "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
                contentType: .documentContent,
                isTruncated: false,
                originalLength: 70
            )

            let redacted = content.redacted

            XCTAssertTrue(redacted.content.contains("[REDACTED]"))
        }

        func testNoRedactionForSafeContent() {
            let content = AppContent(
                appName: "Test",
                appIcon: nil,
                bundleIdentifier: nil,
                windowTitle: nil,
                content: "This is just regular text without any secrets.",
                contentType: .generic,
                isTruncated: false,
                originalLength: 47
            )

            let redacted = content.redacted

            XCTAssertEqual(redacted.content, content.content)
            XCTAssertFalse(redacted.content.contains("[REDACTED]"))
        }

        // MARK: - ContentType Tests

        func testContentTypeDisplayNames() {
            XCTAssertEqual(AppContent.ContentType.selectedText.displayName, "Selected Text")
            XCTAssertEqual(AppContent.ContentType.documentContent.displayName, "Document")
            XCTAssertEqual(AppContent.ContentType.terminalOutput.displayName, "Terminal Output")
            XCTAssertEqual(AppContent.ContentType.browserURL.displayName, "Web Page")
            XCTAssertEqual(AppContent.ContentType.generic.displayName, "Content")
        }

        // MARK: - AppContentResult Tests

        func testResultSuccessContent() {
            let appContent = AppContent(
                appName: "Safari",
                appIcon: nil,
                bundleIdentifier: "com.apple.Safari",
                windowTitle: "Apple",
                content: "Test content",
                contentType: .browserURL,
                isTruncated: false,
                originalLength: 12
            )

            let result = AppContentResult.success(appContent)

            XCTAssertTrue(result.isSuccess)
            XCTAssertNotNil(result.content)
            XCTAssertNil(result.errorMessage)
        }

        func testResultPermissionDenied() {
            let result = AppContentResult.permissionDenied

            XCTAssertFalse(result.isSuccess)
            XCTAssertNil(result.content)
            XCTAssertNotNil(result.errorMessage)
            XCTAssertTrue(result.errorMessage!.contains("permission"))
        }

        func testResultNoFocusedApp() {
            let result = AppContentResult.noFocusedApp

            XCTAssertFalse(result.isSuccess)
            XCTAssertNil(result.content)
            XCTAssertNotNil(result.errorMessage)
        }

        func testResultNoContentAvailable() {
            let result = AppContentResult.noContentAvailable

            XCTAssertFalse(result.isSuccess)
            XCTAssertNil(result.content)
            XCTAssertNotNil(result.errorMessage)
        }

        func testResultExtractionFailed() {
            let result = AppContentResult.extractionFailed(reason: "Test failure")

            XCTAssertFalse(result.isSuccess)
            XCTAssertNil(result.content)
            XCTAssertNotNil(result.errorMessage)
            XCTAssertTrue(result.errorMessage!.contains("Test failure"))
        }
    }
#endif
