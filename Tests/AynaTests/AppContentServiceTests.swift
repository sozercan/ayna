#if os(macOS)
    import AppKit
    @testable import Ayna
    import Testing

    @Suite("AppContentService Tests")
    @MainActor
    struct AppContentServiceTests {
        var service: AppContentService

        init() {
            service = AppContentService.shared
        }

        @Test("Terminal extractor handles Terminal app")
        func terminalExtractorHandlesTerminalApp() {
            let extractor = TerminalExtractor()

            #expect(extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
            #expect(extractor.canHandle(bundleIdentifier: "com.googlecode.iterm2"))
            #expect(extractor.canHandle(bundleIdentifier: "dev.warp.Warp-Stable"))
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
        }

        @Test("Code editor extractor handles editors")
        func codeEditorExtractorHandlesEditors() {
            let extractor = CodeEditorExtractor()

            #expect(extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
            #expect(extractor.canHandle(bundleIdentifier: "com.microsoft.VSCode"))
            #expect(extractor.canHandle(bundleIdentifier: "com.todesktop.230313mzl4w4u92"))
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
        }

        @Test("Browser extractor handles browsers")
        func browserExtractorHandlesBrowsers() {
            let extractor = BrowserExtractor()

            #expect(extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            #expect(extractor.canHandle(bundleIdentifier: "com.google.Chrome"))
            #expect(extractor.canHandle(bundleIdentifier: "company.thebrowser.Browser"))
            #expect(extractor.canHandle(bundleIdentifier: "org.mozilla.firefox"))
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
        }

        @Test("Generic extractor handles anything")
        func genericExtractorHandlesAnything() {
            let extractor = GenericExtractor()

            #expect(extractor.canHandle(bundleIdentifier: "com.anything.app"))
            #expect(extractor.canHandle(bundleIdentifier: "random.bundle.id"))
            #expect(extractor.canHandle(bundleIdentifier: ""))
        }

        @Test("Extract content returns valid result")
        func extractContentReturnsValidResult() async {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Finder" }) else {
                Issue.record("Finder not running - skipping test")
                return
            }

            let result = await service.extractContent(from: app)

            switch result {
            case .success, .permissionDenied, .noContentAvailable, .extractionFailed:
                break
            case .noFocusedApp:
                Issue.record("Should not return noFocusedApp when app is provided")
            }
        }

        @Test("Extract from frontmost app does not crash")
        func extractFromFrontmostAppDoesNotCrash() async {
            let result = await service.extractFromFrontmostApp()

            switch result {
            case .success, .permissionDenied, .noFocusedApp, .noContentAvailable, .extractionFailed:
                break
            }
        }
    }

    @Suite("TerminalExtractor Tests")
    @MainActor
    struct TerminalExtractorTests {
        let extractor = TerminalExtractor()

        @Test("Can handle terminal bundle IDs")
        func canHandleTerminalBundleIds() {
            #expect(extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
            #expect(extractor.canHandle(bundleIdentifier: "com.googlecode.iterm2"))
            #expect(extractor.canHandle(bundleIdentifier: "dev.warp.Warp"))
            #expect(extractor.canHandle(bundleIdentifier: "dev.warp.Warp-Stable"))
            #expect(extractor.canHandle(bundleIdentifier: "com.mitchellh.ghostty"))
        }

        @Test("Cannot handle non-terminals")
        func cannotHandleNonTerminals() {
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            #expect(!extractor.canHandle(bundleIdentifier: "com.microsoft.VSCode"))
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.finder"))
        }
    }

    @Suite("CodeEditorExtractor Tests")
    @MainActor
    struct CodeEditorExtractorTests {
        let extractor = CodeEditorExtractor()

        @Test("Can handle editor bundle IDs")
        func canHandleEditorBundleIds() {
            #expect(extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
            #expect(extractor.canHandle(bundleIdentifier: "com.microsoft.VSCode"))
            #expect(extractor.canHandle(bundleIdentifier: "com.sublimetext.4"))
            #expect(extractor.canHandle(bundleIdentifier: "com.jetbrains.intellij"))
        }

        @Test("Cannot handle non-editors")
        func cannotHandleNonEditors() {
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
        }
    }

    @Suite("BrowserExtractor Tests")
    @MainActor
    struct BrowserExtractorTests {
        let extractor = BrowserExtractor()

        @Test("Can handle browser bundle IDs")
        func canHandleBrowserBundleIds() {
            #expect(extractor.canHandle(bundleIdentifier: "com.apple.Safari"))
            #expect(extractor.canHandle(bundleIdentifier: "com.google.Chrome"))
            #expect(extractor.canHandle(bundleIdentifier: "org.mozilla.firefox"))
            #expect(extractor.canHandle(bundleIdentifier: "com.microsoft.edgemac"))
            #expect(extractor.canHandle(bundleIdentifier: "com.brave.Browser"))
        }

        @Test("Cannot handle non-browsers")
        func cannotHandleNonBrowsers() {
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.Terminal"))
            #expect(!extractor.canHandle(bundleIdentifier: "com.apple.dt.Xcode"))
        }
    }

    @Suite("GenericExtractor Tests")
    @MainActor
    struct GenericExtractorTests {
        let extractor = GenericExtractor()

        @Test("Can handle any bundle ID")
        func canHandleAnyBundleId() {
            #expect(extractor.canHandle(bundleIdentifier: "com.any.app"))
            #expect(extractor.canHandle(bundleIdentifier: ""))
            #expect(extractor.canHandle(bundleIdentifier: "random-string"))
        }
    }
#endif
