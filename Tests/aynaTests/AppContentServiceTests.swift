//
//  AppContentServiceTests.swift
//  aynaTests
//
//  Tests for AppContentService
//

#if os(macOS)
    @testable import Ayna
    import XCTest

    @MainActor
    final class AppContentServiceTests: XCTestCase {
        var service: AppContentService!

        override func setUpWithError() throws {
            try super.setUpWithError()
            service = AppContentService.shared
        }

        // MARK: - Extractor Selection Tests

        func testTerminalExtractorHandlesTerminalApp() {
            let extractor = TerminalExtractor()

            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.googlecode.iterm2"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "dev.warp.Warp-Stable"))
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
        }

        func testCodeEditorExtractorHandlesEditors() {
            let extractor = CodeEditorExtractor()

            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.microsoft.VSCode"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.todesktop.230313mzl4w4u92")) // Cursor
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
        }

        func testBrowserExtractorHandlesBrowsers() {
            let extractor = BrowserExtractor()

            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.google.Chrome"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "company.thebrowser.Browser")) // Arc
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "org.mozilla.firefox"))
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
        }

        func testGenericExtractorHandlesAnything() {
            let extractor = GenericExtractor()

            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.anything.app"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "random.bundle.id"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: ""))
        }

        // MARK: - Permission Tests

        func testExtractContentReturnsPermissionDeniedWhenNotTrusted() async {
            // This test will vary based on whether accessibility is enabled
            // We just verify it doesn't crash
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Finder" }) else {
                XCTSkip("Finder not running")
                return
            }

            let result = await service.extractContent(from: app)

            // Result should be one of the valid states
            switch result {
            case .success, .permissionDenied, .noContentAvailable, .extractionFailed:
                break // Valid
            case .noFocusedApp:
                XCTFail("Should not return noFocusedApp when app is provided")
            }
        }

        // MARK: - Extract From Frontmost Tests

        func testExtractFromFrontmostAppDoesNotCrash() async {
            // This test just verifies the method doesn't crash
            let result = await service.extractFromFrontmostApp()

            // Should return some valid result
            switch result {
            case .success, .permissionDenied, .noFocusedApp, .noContentAvailable, .extractionFailed:
                break // All are valid outcomes
            }
        }
    }

    // MARK: - Individual Extractor Tests

    @MainActor
    final class TerminalExtractorTests: XCTestCase {
        let extractor = TerminalExtractor()

        func testCanHandleTerminalBundleIds() {
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.googlecode.iterm2"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "dev.warp.Warp"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "dev.warp.Warp-Stable"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.mitchellh.ghostty"))
        }

        func testCannotHandleNonTerminals() {
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.microsoft.VSCode"))
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.finder"))
        }
    }

    @MainActor
    final class CodeEditorExtractorTests: XCTestCase {
        let extractor = CodeEditorExtractor()

        func testCanHandleEditorBundleIds() {
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.microsoft.VSCode"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.sublimetext.4"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.jetbrains.intellij"))
        }

        func testCannotHandleNonEditors() {
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
        }
    }

    @MainActor
    final class BrowserExtractorTests: XCTestCase {
        let extractor = BrowserExtractor()

        func testCanHandleBrowserBundleIds() {
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.google.Chrome"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "org.mozilla.firefox"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.microsoft.edgemac"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.brave.Browser"))
        }

        func testCannotHandleNonBrowsers() {
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
            XCTAssertFalse(extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
        }
    }

    @MainActor
    final class GenericExtractorTests: XCTestCase {
        let extractor = GenericExtractor()

        func testCanHandleAnyBundleId() {
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "com.any.app"))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: ""))
            XCTAssertTrue(extractor.canHandle(bundleIdentifier: "random-string"))
        }
    }
#endif
