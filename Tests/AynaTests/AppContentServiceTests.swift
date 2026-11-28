#if os(macOS)
    import AppKit
    @testable import Ayna
    import Testing

    @Suite("AppContentService Tests")
    @MainActor
    struct AppContentServiceTests {
        private final class StubExtractor: AppExtractor {
            let handledBundleID: String?
            let result: AppContentResult
            private(set) var extractCallCount = 0

            init(handledBundleID: String?, result: AppContentResult) {
                self.handledBundleID = handledBundleID
                self.result = result
            }

            func canHandle(bundleIdentifier: String) -> Bool {
                guard let handledBundleID else { return true }
                return bundleIdentifier == handledBundleID
            }

            func extract(from _: NSRunningApplication, element _: AXUIElement) async -> AppContentResult {
                extractCallCount += 1
                return result
            }
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

        @Test("Extract content returns permissionDenied when accessibility permission is missing")
        func extractContentReturnsPermissionDeniedWithoutPermission() async {
            let extractor = StubExtractor(handledBundleID: nil, result: .noContentAvailable)
            let service = AppContentService(
                extractors: [extractor],
                checkPermission: { false }
            )

            let result = await service.extractContent(from: NSRunningApplication.current)

            if case .permissionDenied = result {
                #expect(extractor.extractCallCount == 0)
            } else {
                Issue.record("Expected .permissionDenied, got \(result)")
            }
        }

        @Test("Extract content dispatches to matching extractor and returns its content")
        func extractContentDispatchesToMatchingExtractor() async {
            let currentApp = NSRunningApplication.current
            let expectedContent = AppContent(
                appName: "TestApp",
                appIcon: nil,
                bundleIdentifier: currentApp.bundleIdentifier,
                windowTitle: "Main",
                content: "Captured output",
                contentType: .documentContent,
                isTruncated: false,
                originalLength: 15
            )
            let specific = StubExtractor(
                handledBundleID: currentApp.bundleIdentifier ?? "",
                result: .success(expectedContent)
            )
            let fallback = StubExtractor(handledBundleID: nil, result: .noContentAvailable)
            let service = AppContentService(
                extractors: [specific, fallback],
                checkPermission: { true }
            )

            let result = await service.extractContent(from: currentApp)

            #expect(specific.extractCallCount == 1)
            #expect(fallback.extractCallCount == 0)
            #expect(AppContent.hasSamePayload(result.content, expectedContent))
        }

        @Test("Extract content falls back to last extractor when none match")
        func extractContentFallsBackToLastExtractor() async {
            let nonMatching = StubExtractor(handledBundleID: "com.nonexistent.app", result: .noContentAvailable)
            let fallback = StubExtractor(handledBundleID: "com.other.app", result: .extractionFailed(reason: "fallback used"))
            let service = AppContentService(
                extractors: [nonMatching, fallback],
                checkPermission: { true }
            )

            let result = await service.extractContent(from: NSRunningApplication.current)

            #expect(nonMatching.extractCallCount == 0)
            #expect(fallback.extractCallCount == 1)
            if case let .extractionFailed(reason) = result {
                #expect(reason == "fallback used")
            } else {
                Issue.record("Expected fallback extractionFailed result, got \(result)")
            }
        }

        @Test("Extract from frontmost app returns noFocusedApp when workspace has no frontmost app")
        func extractFromFrontmostAppReturnsNoFocusedAppWhenNil() async {
            let service = AppContentService(
                extractors: [],
                checkPermission: { true },
                frontmostApplicationProvider: { nil }
            )

            let result = await service.extractFromFrontmostApp()

            if case .noFocusedApp = result {
            } else {
                Issue.record("Expected .noFocusedApp, got \(result)")
            }
        }

        @Test("Extract from frontmost app returns noContentAvailable when frontmost app is Ayna itself")
        func extractFromFrontmostAppIgnoresOwnApp() async {
            let currentApp = NSRunningApplication.current
            let extractor = StubExtractor(handledBundleID: nil, result: .noFocusedApp)
            let service = AppContentService(
                extractors: [extractor],
                checkPermission: { true },
                frontmostApplicationProvider: { currentApp },
                appBundleIdentifierProvider: { _ in "com.sertacozercan.ayna" },
                ownBundleIdentifierProvider: { "com.sertacozercan.ayna" }
            )

            let result = await service.extractFromFrontmostApp()

            if case .noContentAvailable = result {
                #expect(extractor.extractCallCount == 0)
            } else {
                Issue.record("Expected .noContentAvailable for own app, got \(result)")
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

        @Test("Normalizes valid browser URLs")
        func normalizesValidBrowserURLs() {
            #expect(BrowserExtractor.normalizedBrowserURL(from: "https://github.com/sozercan/ayna") == "https://github.com/sozercan/ayna")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "http://localhost:3000/dashboard") == "http://localhost:3000/dashboard")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "github.com/sozercan/ayna") == "https://github.com/sozercan/ayna")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "EXAMPLE.COM/path") == "https://EXAMPLE.COM/path")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "LOCALHOST:8080") == "https://LOCALHOST:8080")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "example.com/?next=https://other.example/") == "https://example.com/?next=https://other.example/")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "[::1]") == "https://[::1]")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "[::1]:8080/status") == "https://[::1]:8080/status")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "https://xn--e1afmkfd.xn--p1ai/") == "https://xn--e1afmkfd.xn--p1ai/")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "http://intranet/dashboard") == "http://intranet/dashboard")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "https://example.com./") == "https://example.com./")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "example.com./path") == "https://example.com./path")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "localhost:8080/api") == "https://localhost:8080/api")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "127.0.0.1:8080") == "https://127.0.0.1:8080")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "  https://example.com/path?q=1  ") == "https://example.com/path?q=1")
            #expect(BrowserExtractor.normalizedBrowserURL(from: "file:///Users/test/index.html") == "file:///Users/test/index.html")
        }

        @Test("Rejects non-URL text with periods and unsupported schemes")
        func rejectsNonURLTextWithPeriods() {
            #expect(BrowserExtractor.normalizedBrowserURL(from: nil) == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "") == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "Hello world. This is a sentence.") == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "v1.2.3") == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "javascript:alert(1)") == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "mailto:user@example.com") == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "https://") == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "ftp://files.example.com") == nil)
            #expect(BrowserExtractor.normalizedBrowserURL(from: "[::1]:invalid") == nil)
        }

        @Test("Identifies address bar roles and descriptors")
        func identifiesAddressBarRolesAndDescriptors() {
            #expect(BrowserExtractor.isAddressBarRole("AXTextField"))
            #expect(BrowserExtractor.isAddressBarRole("AXComboBox"))
            #expect(!BrowserExtractor.isAddressBarRole("AXTextArea"))
            #expect(!BrowserExtractor.isAddressBarRole(nil))

            #expect(BrowserExtractor.isAddressBarDescriptor(
                identifier: "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD",
                description: nil,
                title: nil,
                subrole: nil
            ))
            #expect(BrowserExtractor.isAddressBarDescriptor(
                identifier: nil,
                description: "Address and search bar",
                title: nil,
                subrole: nil
            ))
            #expect(BrowserExtractor.isAddressBarDescriptor(
                identifier: "urlbar-input",
                description: nil,
                title: nil,
                subrole: nil
            ))
            #expect(!BrowserExtractor.isAddressBarDescriptor(
                identifier: "search-input",
                description: "Find in page",
                title: "Search",
                subrole: nil
            ))
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
