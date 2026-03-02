//
//  AppContentTests.swift
//  aynaTests
//
//  Tests for AppContent model and related types
//

#if os(macOS)
    @testable import Ayna
    import Testing

    @Suite("AppContent Tests")
    struct AppContentTests {
        // MARK: - AppContent Tests

        @Test("Truncation of short content")
        func truncationShortContent() {
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

            #expect(truncated.content == "Short content")
            #expect(!truncated.isTruncated)
        }

        @Test("Truncation of long content")
        func truncationLongContent() {
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

            #expect(truncated.isTruncated)
            #expect(truncated.content.contains("[Content truncated"))
            #expect(truncated.content.count < 5000)
        }

        @Test("Truncation without indicator")
        func truncationWithoutIndicator() {
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

            #expect(truncated.isTruncated)
            #expect(truncated.content.count == 50)
            #expect(!truncated.content.contains("[Content truncated"))
            // Terminal content should keep the END (suffix)
            #expect(truncated.content.hasSuffix(String(repeating: "b", count: 50)))
        }

        @Test("Terminal truncation keeps end")
        func terminalTruncationKeepsEnd() {
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
            #expect(truncated.content.contains("END_MARKER"))
            #expect(!truncated.content.contains("START_MARKER"))
        }

        @Test("Document truncation keeps start")
        func documentTruncationKeepsStart() {
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
            #expect(truncated.content.contains("START_MARKER"))
            #expect(!truncated.content.contains("END_MARKER"))
        }

        @Test("forModel property truncates to model limit")
        func forModelLimit() {
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
            #expect(forModel.isTruncated)
            #expect(forModel.content.hasPrefix(String(repeating: "c", count: 100)))
            // Total should be around 16000 + indicator text length
            #expect(forModel.content.count < 17000)
        }

        @Test("forPreview property truncates to preview limit")
        func forPreviewLimit() {
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
            #expect(forPreview.isTruncated)
        }

        // MARK: - Secret Redaction Tests

        @Test("Redact OpenAI key")
        func redactOpenAIKey() {
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

            #expect(redacted.content.contains("[REDACTED]"))
            #expect(!redacted.content.contains("sk-proj"))
        }

        @Test("Redact GitHub token")
        func redactGitHubToken() {
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

            #expect(redacted.content.contains("[REDACTED]"))
            #expect(!redacted.content.contains("ghp_"))
        }

        @Test("Redact bearer token")
        func redactBearerToken() {
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

            #expect(redacted.content.contains("[REDACTED]"))
        }

        @Test("No redaction for safe content")
        func noRedactionForSafeContent() {
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

            #expect(redacted.content == content.content)
            #expect(!redacted.content.contains("[REDACTED]"))
        }

        // MARK: - ContentType Tests

        @Test("Content type display names")
        func contentTypeDisplayNames() {
            #expect(AppContent.ContentType.selectedText.displayName == "Selected Text")
            #expect(AppContent.ContentType.documentContent.displayName == "Document")
            #expect(AppContent.ContentType.terminalOutput.displayName == "Terminal Output")
            #expect(AppContent.ContentType.browserURL.displayName == "Web Page")
            #expect(AppContent.ContentType.generic.displayName == "Content")
        }

        // MARK: - AppContentResult Tests

        @Test("Result success content")
        func resultSuccessContent() {
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

            #expect(result.isSuccess)
            #expect(result.content != nil)
            #expect(result.errorMessage == nil)
        }

        @Test("Result permission denied")
        func resultPermissionDenied() throws {
            let result = AppContentResult.permissionDenied

            #expect(!result.isSuccess)
            #expect(result.content == nil)
            #expect(result.errorMessage != nil)
            #expect(try #require(result.errorMessage?.contains("permission") as Bool?))
        }

        @Test("Result no focused app")
        func resultNoFocusedApp() {
            let result = AppContentResult.noFocusedApp

            #expect(!result.isSuccess)
            #expect(result.content == nil)
            #expect(result.errorMessage != nil)
        }

        @Test("Result no content available")
        func resultNoContentAvailable() {
            let result = AppContentResult.noContentAvailable

            #expect(!result.isSuccess)
            #expect(result.content == nil)
            #expect(result.errorMessage != nil)
        }

        @Test("Result extraction failed")
        func resultExtractionFailed() throws {
            let result = AppContentResult.extractionFailed(reason: "Test failure")

            #expect(!result.isSuccess)
            #expect(result.content == nil)
            #expect(result.errorMessage != nil)
            #expect(try #require(result.errorMessage?.contains("Test failure") as Bool?))
        }
    }
#endif
