#if os(macOS)
    import AppKit
    import ApplicationServices

    enum TruncationStrategy {
        case keepEnd
        case keepStart
        case smartAnchors
    }

    enum TokenBudget {
        static let defaultBudget = 4000

        static func estimateTokens(_ text: String) -> Int {
            (text.count + 3) / 4
        }

        static func charactersForTokens(_ tokens: Int) -> Int {
            tokens * 4
        }

        static let errorPatterns = [
            "error:", "Error:", "ERROR",
            "failed", "Failed", "FAILED",
            "exception", "Exception", "EXCEPTION",
            "warning:", "Warning:", "WARNING",
            "fatal:", "Fatal:", "FATAL",
            "panic:", "Panic:",
            "undefined", "Undefined",
            "null pointer", "NullPointer",
            "stack trace", "Traceback",
            "segmentation fault", "SIGSEGV",
            "abort", "SIGABRT"
        ]

        static func containsError(_ line: String) -> Bool {
            errorPatterns.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }

    private struct CommandBlock {
        let startIndex: Int
        let endIndex: Int
        let hasError: Bool
    }

    enum SmartTruncation {
        static func truncateTerminal(_ content: String, maxTokens: Int = TokenBudget.defaultBudget) -> (content: String, truncated: Bool) {
            let maxChars = TokenBudget.charactersForTokens(maxTokens)
            let lines = content.components(separatedBy: .newlines)

            if content.count <= maxChars {
                return (content, false)
            }

            let promptPatterns = ["$ ", "❯ ", "% ", "> ", "# ", "➜ ", "└─", "╰─"]

            var commandBlocks: [CommandBlock] = []
            var currentBlockStart: Int?
            var currentBlockHasError = false

            for (index, line) in lines.enumerated() {
                let isPrompt = promptPatterns.contains { line.contains($0) }

                if isPrompt {
                    if let start = currentBlockStart {
                        commandBlocks.append(CommandBlock(startIndex: start, endIndex: index - 1, hasError: currentBlockHasError))
                    }
                    currentBlockStart = index
                    currentBlockHasError = false
                }

                if TokenBudget.containsError(line) {
                    currentBlockHasError = true
                }
            }

            if let start = currentBlockStart {
                commandBlocks.append(CommandBlock(startIndex: start, endIndex: lines.count - 1, hasError: currentBlockHasError))
            }

            if commandBlocks.isEmpty {
                return truncateKeepEnd(content, maxTokens: maxTokens)
            }

            var selectedLines: [String] = []
            var currentChars = 0

            if let lastBlock = commandBlocks.last {
                let blockLines = Array(lines[lastBlock.startIndex ... lastBlock.endIndex])
                let blockContent = blockLines.joined(separator: "\n")
                selectedLines = blockLines
                currentChars = blockContent.count
            }

            let errorBlocks = commandBlocks.dropLast().filter(\.hasError).reversed()
            for block in errorBlocks {
                let blockLines = Array(lines[block.startIndex ... block.endIndex])
                let blockContent = blockLines.joined(separator: "\n")

                if currentChars + blockContent.count + 50 < maxChars {
                    let gapIndicator = "\n// ... [earlier output omitted] ...\n"
                    selectedLines = blockLines + [gapIndicator] + selectedLines
                    currentChars += blockContent.count + gapIndicator.count
                }
            }

            let recentBlocks = commandBlocks.dropLast().filter { !$0.hasError }.reversed()
            for block in recentBlocks {
                let blockLines = Array(lines[block.startIndex ... block.endIndex])
                let blockContent = blockLines.joined(separator: "\n")

                if currentChars + blockContent.count + 50 < maxChars {
                    let gapIndicator = "\n// ... [earlier output omitted] ...\n"
                    selectedLines = blockLines + [gapIndicator] + selectedLines
                    currentChars += blockContent.count + gapIndicator.count
                } else {
                    break
                }
            }

            let result = selectedLines.joined(separator: "\n")
            return (result, true)
        }

        static func truncateCode(_ content: String, maxTokens: Int = TokenBudget.defaultBudget) -> (content: String, truncated: Bool) {
            let maxChars = TokenBudget.charactersForTokens(maxTokens)

            guard content.count > maxChars else {
                return (content, false)
            }

            let lines = content.components(separatedBy: .newlines)

            let headBudget = maxChars / 8
            let tailBudget = maxChars / 16
            let cursorBudget = maxChars - headBudget - tailBudget

            let importPatterns = ["import ", "#include", "package ", "use ", "from ", "require", "using ", "@import", "module "]
            var headEndIndex = 0
            var headChars = 0

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if headChars > headBudget { break }

                let isImport = importPatterns.contains { trimmed.hasPrefix($0) }
                let isEmpty = trimmed.isEmpty
                let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") || trimmed.hasPrefix("#")

                if isImport || isEmpty || isComment || index < 5 {
                    headEndIndex = index
                    headChars += line.count + 1
                } else if !isImport, headChars > 100 {
                    break
                }
            }

            let headLines = Array(lines[0 ... min(headEndIndex, lines.count - 1)])

            var tailStartIndex = lines.count
            var tailChars = 0

            for index in stride(from: lines.count - 1, through: 0, by: -1) {
                let line = lines[index]
                if tailChars + line.count + 1 > tailBudget { break }

                tailStartIndex = index
                tailChars += line.count + 1
            }

            let tailLines = tailStartIndex < lines.count ? Array(lines[tailStartIndex...]) : []

            let middleStart = headEndIndex + 1
            let middleEnd = tailStartIndex - 1

            guard middleStart < middleEnd else {
                let result = (headLines + tailLines).joined(separator: "\n")
                return (result, true)
            }

            let middleLines = Array(lines[middleStart ... middleEnd])

            var errorLineIndices: [Int] = []
            for (index, line) in middleLines.enumerated() where TokenBudget.containsError(line) {
                errorLineIndices.append(index)
            }

            var selectedMiddleLines: [String] = []
            var middleChars = 0

            if !errorLineIndices.isEmpty {
                for errorIndex in errorLineIndices {
                    let contextStart = max(0, errorIndex - 10)
                    let contextEnd = min(middleLines.count - 1, errorIndex + 5)
                    let contextLines = Array(middleLines[contextStart ... contextEnd])
                    let contextContent = contextLines.joined(separator: "\n")

                    if middleChars + contextContent.count < cursorBudget {
                        if !selectedMiddleLines.isEmpty {
                            selectedMiddleLines.append("// ... [code omitted] ...")
                        }
                        selectedMiddleLines.append(contentsOf: contextLines)
                        middleChars += contextContent.count
                    }
                }
            }

            if middleChars < cursorBudget {
                let centerIndex = middleLines.count / 2
                let remainingBudget = cursorBudget - middleChars
                var centerLines: [String] = []
                var centerChars = 0
                var offset = 0

                while centerChars < remainingBudget, offset < middleLines.count / 2 {
                    let beforeIndex = centerIndex - offset
                    let afterIndex = centerIndex + offset

                    if beforeIndex >= 0, beforeIndex < middleLines.count {
                        let line = middleLines[beforeIndex]
                        if centerChars + line.count < remainingBudget {
                            centerLines.insert(line, at: 0)
                            centerChars += line.count + 1
                        }
                    }

                    if afterIndex < middleLines.count, afterIndex != beforeIndex {
                        let line = middleLines[afterIndex]
                        if centerChars + line.count < remainingBudget {
                            centerLines.append(line)
                            centerChars += line.count + 1
                        }
                    }

                    offset += 1
                }

                if !selectedMiddleLines.isEmpty, !centerLines.isEmpty {
                    selectedMiddleLines.append("// ... [code omitted] ...")
                }
                selectedMiddleLines.append(contentsOf: centerLines)
            }

            var resultLines = headLines

            if !selectedMiddleLines.isEmpty {
                let omittedBefore = middleStart - headEndIndex - 1
                if omittedBefore > 0 {
                    resultLines.append("// ... [\(omittedBefore) lines omitted] ...")
                }
                resultLines.append(contentsOf: selectedMiddleLines)
            }

            if !tailLines.isEmpty {
                let omittedAfter = tailStartIndex - (middleStart + selectedMiddleLines.count - selectedMiddleLines.filter { $0 == "// ... [code omitted] ..." }.count)
                if omittedAfter > 10 {
                    resultLines.append("// ... [\(omittedAfter) lines omitted] ...")
                }
                resultLines.append(contentsOf: tailLines)
            }

            let result = resultLines.joined(separator: "\n")
            return (result, true)
        }

        static func truncateKeepEnd(_ content: String, maxTokens: Int = TokenBudget.defaultBudget) -> (content: String, truncated: Bool) {
            let maxChars = TokenBudget.charactersForTokens(maxTokens)

            guard content.count > maxChars else {
                return (content, false)
            }

            let lines = content.components(separatedBy: .newlines)
            var selectedLines: [String] = []
            var charCount = 0

            for line in lines.reversed() {
                if charCount + line.count + 1 > maxChars { break }
                selectedLines.insert(line, at: 0)
                charCount += line.count + 1
            }

            let omitted = lines.count - selectedLines.count
            if omitted > 0 {
                selectedLines.insert("// ... [\(omitted) lines omitted] ...", at: 0)
            }

            return (selectedLines.joined(separator: "\n"), true)
        }

        static func truncateKeepStart(_ content: String, maxTokens: Int = TokenBudget.defaultBudget) -> (content: String, truncated: Bool) {
            let maxChars = TokenBudget.charactersForTokens(maxTokens)

            guard content.count > maxChars else {
                return (content, false)
            }

            let lines = content.components(separatedBy: .newlines)
            var selectedLines: [String] = []
            var charCount = 0

            for line in lines {
                if charCount + line.count + 1 > maxChars { break }
                selectedLines.append(line)
                charCount += line.count + 1
            }

            let omitted = lines.count - selectedLines.count
            if omitted > 0 {
                selectedLines.append("// ... [\(omitted) lines omitted] ...")
            }

            return (selectedLines.joined(separator: "\n"), true)
        }
    }

    @MainActor
    final class AppContentService {
        static let shared = AppContentService()

        private let extractors: [AppExtractor] = [
            TerminalExtractor(),
            CodeEditorExtractor(),
            BrowserExtractor(),
            GenericExtractor()
        ]

        private init() {}

        func extractContent(from app: NSRunningApplication) async -> AppContentResult {
            guard AccessibilityService.shared.checkPermission(prompt: false) else {
                return .permissionDenied
            }

            let bundleId = app.bundleIdentifier ?? ""

            let appElement = AccessibilityService.shared.createApplicationElement(for: app)

            guard let extractor = extractors.first(where: { $0.canHandle(bundleIdentifier: bundleId) })
                ?? extractors.last
            else {
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .error,
                    message: "No content extractors available"
                )
                return .extractionFailed(reason: "No content extractors available")
            }

            DiagnosticsLogger.log(
                .attachFromApp,
                level: .info,
                message: "Extracting content",
                metadata: [
                    "app": app.localizedName ?? "Unknown",
                    "bundleId": bundleId,
                    "extractor": String(describing: type(of: extractor))
                ]
            )

            let result = await extractor.extract(from: app, element: appElement)

            switch result {
            case let .success(content):
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .info,
                    message: "Content extracted successfully",
                    metadata: [
                        "contentType": content.contentType.rawValue,
                        "length": "\(content.content.count)",
                        "truncated": "\(content.isTruncated)",
                        "estimatedTokens": "\(TokenBudget.estimateTokens(content.content))"
                    ]
                )
            case let .extractionFailed(reason):
                DiagnosticsLogger.log(
                    .attachFromApp,
                    level: .error,
                    message: "Content extraction failed",
                    metadata: ["reason": reason]
                )
            default:
                break
            }

            return result
        }

        func extractFromFrontmostApp() async -> AppContentResult {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return .noFocusedApp
            }

            if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier {
                return .noContentAvailable
            }

            return await extractContent(from: frontApp)
        }
    }

    @MainActor
    protocol AppExtractor {
        func canHandle(bundleIdentifier: String) -> Bool

        func extract(from app: NSRunningApplication, element: AXUIElement) async -> AppContentResult
    }

    struct TerminalExtractor: AppExtractor {
        private let terminalBundleIds = [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "dev.warp.Warp-Stable",
            "dev.warp.Warp",
            "com.mitchellh.ghostty",
            "io.alacritty"
        ]

        func canHandle(bundleIdentifier: String) -> Bool {
            terminalBundleIds.contains { bundleIdentifier.hasPrefix($0) }
        }

        func extract(from app: NSRunningApplication, element: AXUIElement) async -> AppContentResult {
            let accessibility = AccessibilityService.shared

            let windowTitle = accessibility.getWindowTitle(in: element)

            if let focused = accessibility.getFocusedElement(in: element),
               let selectedText = accessibility.getSelectedText(focused),
               !selectedText.isEmpty
            {
                let (content, truncated) = SmartTruncation.truncateTerminal(selectedText)
                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: content,
                    contentType: .selectedText,
                    truncated: truncated,
                    originalLength: selectedText.count
                ))
            }

            if let focused = accessibility.getFocusedElement(in: element),
               let value = accessibility.getValue(focused)
            {
                let (content, truncated) = SmartTruncation.truncateTerminal(value)

                if !content.isEmpty {
                    return .success(createContent(
                        app: app,
                        windowTitle: windowTitle,
                        content: content,
                        contentType: .terminalOutput,
                        truncated: truncated,
                        originalLength: value.count
                    ))
                }
            }

            return .noContentAvailable
        }

        private func createContent(
            app: NSRunningApplication,
            windowTitle: String?,
            content: String,
            contentType: AppContent.ContentType,
            truncated: Bool,
            originalLength: Int
        ) -> AppContent {
            AppContent(
                appName: app.localizedName ?? "Terminal",
                appIcon: app.icon,
                bundleIdentifier: app.bundleIdentifier,
                windowTitle: windowTitle,
                content: content,
                contentType: contentType,
                isTruncated: truncated,
                originalLength: originalLength
            )
        }
    }

    struct CodeEditorExtractor: AppExtractor {
        private let editorPatterns = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "com.sublimetext",
            "com.jetbrains",
            "com.panic.Nova",
            "abnerworks.Typora",
            "com.coteditor.CotEditor"
        ]

        func canHandle(bundleIdentifier: String) -> Bool {
            editorPatterns.contains { bundleIdentifier.hasPrefix($0) }
        }

        func extract(from app: NSRunningApplication, element: AXUIElement) async -> AppContentResult {
            let accessibility = AccessibilityService.shared

            let windowTitle = accessibility.getWindowTitle(in: element)

            if let focused = accessibility.getFocusedElement(in: element),
               let selectedText = accessibility.getSelectedText(focused),
               !selectedText.isEmpty
            {
                let (content, truncated) = SmartTruncation.truncateCode(selectedText)
                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: content,
                    contentType: .selectedText,
                    truncated: truncated,
                    originalLength: selectedText.count
                ))
            }

            if let focused = accessibility.getFocusedElement(in: element),
               let value = accessibility.getValue(focused)
            {
                let (content, truncated) = SmartTruncation.truncateCode(value)

                if !content.isEmpty {
                    return .success(createContent(
                        app: app,
                        windowTitle: windowTitle,
                        content: content,
                        contentType: .documentContent,
                        truncated: truncated,
                        originalLength: value.count
                    ))
                }
            }

            return .noContentAvailable
        }

        private func createContent(
            app: NSRunningApplication,
            windowTitle: String?,
            content: String,
            contentType: AppContent.ContentType,
            truncated: Bool,
            originalLength: Int
        ) -> AppContent {
            AppContent(
                appName: app.localizedName ?? "Editor",
                appIcon: app.icon,
                bundleIdentifier: app.bundleIdentifier,
                windowTitle: windowTitle,
                content: content,
                contentType: contentType,
                isTruncated: truncated,
                originalLength: originalLength
            )
        }
    }

    struct BrowserExtractor: AppExtractor {
        private let browserPatterns = [
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser",
            "org.mozilla.firefox",
            "com.microsoft.edgemac",
            "com.brave.Browser",
            "com.operasoftware.Opera"
        ]

        func canHandle(bundleIdentifier: String) -> Bool {
            browserPatterns.contains { bundleIdentifier.hasPrefix($0) }
        }

        func extract(from app: NSRunningApplication, element: AXUIElement) async -> AppContentResult {
            let accessibility = AccessibilityService.shared

            let windowTitle = accessibility.getWindowTitle(in: element)

            if let focused = accessibility.getFocusedElement(in: element),
               let selectedText = accessibility.getSelectedText(focused),
               !selectedText.isEmpty
            {
                let (content, truncated) = SmartTruncation.truncateKeepStart(selectedText)
                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: content,
                    contentType: .selectedText,
                    truncated: truncated,
                    originalLength: selectedText.count
                ))
            }

            let url = await findURLFromBrowser(element: element)

            if let url, !url.isEmpty {
                var content = "URL: \(url)"
                if let title = windowTitle {
                    content = "Page: \(title)\n\(content)"
                }

                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: content,
                    contentType: .browserURL,
                    truncated: false,
                    originalLength: content.count
                ))
            }

            if let title = windowTitle, !title.isEmpty {
                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: "Viewing: \(title)",
                    contentType: .browserURL,
                    truncated: false,
                    originalLength: title.count
                ))
            }

            return .noContentAvailable
        }

        private func findURLFromBrowser(element: AXUIElement) async -> String? {
            var result: String?

            if let focused = AccessibilityService.shared.getFocusedElement(in: element) {
                if let value = AccessibilityService.shared.getValue(focused) {
                    if value.hasPrefix("http://") || value.hasPrefix("https://") || value.contains(".") {
                        result = value
                    }
                }
            }

            return result
        }

        private func createContent(
            app: NSRunningApplication,
            windowTitle: String?,
            content: String,
            contentType: AppContent.ContentType,
            truncated: Bool,
            originalLength: Int
        ) -> AppContent {
            AppContent(
                appName: app.localizedName ?? "Browser",
                appIcon: app.icon,
                bundleIdentifier: app.bundleIdentifier,
                windowTitle: windowTitle,
                content: content,
                contentType: contentType,
                isTruncated: truncated,
                originalLength: originalLength
            )
        }
    }

    struct GenericExtractor: AppExtractor {
        func canHandle(bundleIdentifier _: String) -> Bool {
            true
        }

        func extract(from app: NSRunningApplication, element: AXUIElement) async -> AppContentResult {
            let accessibility = AccessibilityService.shared

            let windowTitle = accessibility.getWindowTitle(in: element)

            if let focused = accessibility.getFocusedElement(in: element),
               let selectedText = accessibility.getSelectedText(focused),
               !selectedText.isEmpty
            {
                let (content, truncated) = SmartTruncation.truncateKeepStart(selectedText)
                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: content,
                    contentType: .selectedText,
                    truncated: truncated,
                    originalLength: selectedText.count
                ))
            }

            if let focused = accessibility.getFocusedElement(in: element),
               let value = accessibility.getValue(focused),
               !value.isEmpty
            {
                let (content, truncated) = SmartTruncation.truncateKeepStart(value)
                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: content,
                    contentType: .generic,
                    truncated: truncated,
                    originalLength: value.count
                ))
            }

            if let title = windowTitle, !title.isEmpty {
                return .success(createContent(
                    app: app,
                    windowTitle: windowTitle,
                    content: "Active window: \(title)",
                    contentType: .generic,
                    truncated: false,
                    originalLength: title.count
                ))
            }

            return .noContentAvailable
        }

        private func createContent(
            app: NSRunningApplication,
            windowTitle: String?,
            content: String,
            contentType: AppContent.ContentType,
            truncated: Bool,
            originalLength: Int
        ) -> AppContent {
            AppContent(
                appName: app.localizedName ?? "Application",
                appIcon: app.icon,
                bundleIdentifier: app.bundleIdentifier,
                windowTitle: windowTitle,
                content: content,
                contentType: contentType,
                isTruncated: truncated,
                originalLength: originalLength
            )
        }
    }
#endif
