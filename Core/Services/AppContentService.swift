//
//  AppContentService.swift
//  ayna
//
//  Extracts content from focused applications using Accessibility APIs.
//

#if os(macOS)
    import AppKit
    import ApplicationServices

    // MARK: - Token Budget & Truncation Utilities

    /// Strategies for truncating content when it exceeds the token budget
    enum TruncationStrategy {
        case keepEnd // Terminal: keep recent output
        case keepStart // Documentation: keep beginning
        case smartAnchors // Code: keep head + cursor area + tail
    }

    /// Utilities for token-based content management
    enum TokenBudget {
        /// Default token budget for extracted content (~16KB)
        static let defaultBudget = 4000

        /// Approximate token count (1 token ≈ 4 characters for English text)
        static func estimateTokens(_ text: String) -> Int {
            (text.count + 3) / 4
        }

        /// Approximate character count for a token budget
        static func charactersForTokens(_ tokens: Int) -> Int {
            tokens * 4
        }

        /// Error patterns to prioritize in extracted content
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

        /// Check if a line contains an error pattern
        static func containsError(_ line: String) -> Bool {
            errorPatterns.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }

    // MARK: - Smart Content Truncation

    /// Represents a command block in terminal output
    private struct CommandBlock {
        let startIndex: Int
        let endIndex: Int
        let hasError: Bool
    }

    /// Handles intelligent content truncation based on token budgets
    enum SmartTruncation {
        /// Truncate terminal output intelligently, keeping recent commands and errors
        /// For terminals, we ALWAYS prefer the end (most recent output) even if content fits budget
        static func truncateTerminal(_ content: String, maxTokens: Int = TokenBudget.defaultBudget) -> (content: String, truncated: Bool) {
            let maxChars = TokenBudget.charactersForTokens(maxTokens)
            let lines = content.components(separatedBy: .newlines)

            // For terminal, ALWAYS take from the end first, then apply smart selection
            // This ensures we get the most recent output even if the raw content starts from top

            // If content fits in budget, still prefer the end (last N lines)
            if content.count <= maxChars {
                return (content, false)
            }

            // Common shell prompt patterns
            let promptPatterns = ["$ ", "❯ ", "% ", "> ", "# ", "➜ ", "└─", "╰─"]

            // Find command boundaries (lines that look like prompts)
            var commandBlocks: [CommandBlock] = []
            var currentBlockStart: Int?
            var currentBlockHasError = false

            for (index, line) in lines.enumerated() {
                let isPrompt = promptPatterns.contains { line.contains($0) }

                if isPrompt {
                    // Save previous block if exists
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

            // Don't forget the last block
            if let start = currentBlockStart {
                commandBlocks.append(CommandBlock(startIndex: start, endIndex: lines.count - 1, hasError: currentBlockHasError))
            }

            // If no command blocks found, fall back to keeping the end
            if commandBlocks.isEmpty {
                return truncateKeepEnd(content, maxTokens: maxTokens)
            }

            // Build content from most recent blocks, prioritizing those with errors
            var selectedLines: [String] = []
            var currentChars = 0

            // Always include the last command block first
            if let lastBlock = commandBlocks.last {
                let blockLines = Array(lines[lastBlock.startIndex ... lastBlock.endIndex])
                let blockContent = blockLines.joined(separator: "\n")
                selectedLines = blockLines
                currentChars = blockContent.count
            }

            // Add previous blocks that have errors (if space allows)
            let errorBlocks = commandBlocks.dropLast().filter(\.hasError).reversed()
            for block in errorBlocks {
                let blockLines = Array(lines[block.startIndex ... block.endIndex])
                let blockContent = blockLines.joined(separator: "\n")

                if currentChars + blockContent.count + 50 < maxChars { // +50 for gap indicator
                    let gapIndicator = "\n// ... [earlier output omitted] ...\n"
                    selectedLines = blockLines + [gapIndicator] + selectedLines
                    currentChars += blockContent.count + gapIndicator.count
                }
            }

            // Fill remaining space with recent non-error blocks
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

        /// Truncate code with smart anchors: head (imports) + cursor area + tail
        static func truncateCode(_ content: String, maxTokens: Int = TokenBudget.defaultBudget) -> (content: String, truncated: Bool) {
            let maxChars = TokenBudget.charactersForTokens(maxTokens)

            guard content.count > maxChars else {
                return (content, false)
            }

            let lines = content.components(separatedBy: .newlines)

            // Budget allocation
            let headBudget = maxChars / 8 // ~12.5% for imports/header
            let tailBudget = maxChars / 16 // ~6.25% for closing structure
            let cursorBudget = maxChars - headBudget - tailBudget // ~81.25% for main content

            // === HEAD SECTION: Imports and declarations ===
            let importPatterns = ["import ", "#include", "package ", "use ", "from ", "require", "using ", "@import", "module "]
            var headEndIndex = 0
            var headChars = 0

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Stop if we've used our head budget
                if headChars > headBudget { break }

                // Include imports, empty lines, and comments at the top
                let isImport = importPatterns.contains { trimmed.hasPrefix($0) }
                let isEmpty = trimmed.isEmpty
                let isComment = trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") || trimmed.hasPrefix("#")

                if isImport || isEmpty || isComment || index < 5 {
                    headEndIndex = index
                    headChars += line.count + 1
                } else if !isImport, headChars > 100 {
                    // We've passed the import section
                    break
                }
            }

            let headLines = Array(lines[0 ... min(headEndIndex, lines.count - 1)])

            // === TAIL SECTION: Closing braces/structure ===
            var tailStartIndex = lines.count
            var tailChars = 0

            for index in stride(from: lines.count - 1, through: 0, by: -1) {
                let line = lines[index]
                if tailChars + line.count + 1 > tailBudget { break }

                tailStartIndex = index
                tailChars += line.count + 1
            }

            let tailLines = tailStartIndex < lines.count ? Array(lines[tailStartIndex...]) : []

            // === CURSOR/MIDDLE SECTION ===
            // Take content from the middle, prioritizing areas with errors
            let middleStart = headEndIndex + 1
            let middleEnd = tailStartIndex - 1

            guard middleStart < middleEnd else {
                // File is small enough that head + tail covers it
                let result = (headLines + tailLines).joined(separator: "\n")
                return (result, true)
            }

            let middleLines = Array(lines[middleStart ... middleEnd])

            // Look for error lines in the middle section
            var errorLineIndices: [Int] = []
            for (index, line) in middleLines.enumerated() where TokenBudget.containsError(line) {
                errorLineIndices.append(index)
            }

            var selectedMiddleLines: [String] = []
            var middleChars = 0

            if !errorLineIndices.isEmpty {
                // Prioritize context around errors
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

            // Fill remaining budget from the center
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

            // Combine all sections
            var resultLines = headLines

            if !selectedMiddleLines.isEmpty {
                let omittedBefore = middleStart - headEndIndex - 1
                if omittedBefore > 0 {
                    resultLines.append("// ... [\(omittedBefore) lines omitted] ...")
                }
                resultLines.append(contentsOf: selectedMiddleLines)
            }

            if !tailLines.isEmpty {
                let omittedAfter = tailStartIndex - (middleStart + selectedMiddleLines.count)
                if omittedAfter > 10 {
                    resultLines.append("// ... [\(omittedAfter) lines omitted] ...")
                }
                resultLines.append(contentsOf: tailLines)
            }

            let result = resultLines.joined(separator: "\n")
            return (result, true)
        }

        /// Simple truncation keeping the end (fallback for terminal)
        static func truncateKeepEnd(_ content: String, maxTokens: Int = TokenBudget.defaultBudget) -> (content: String, truncated: Bool) {
            let maxChars = TokenBudget.charactersForTokens(maxTokens)

            guard content.count > maxChars else {
                return (content, false)
            }

            let lines = content.components(separatedBy: .newlines)
            var selectedLines: [String] = []
            var charCount = 0

            // Take lines from the end
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

        /// Simple truncation keeping the start
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

    // MARK: - App Content Service

    /// Service for extracting content from applications using Accessibility APIs.
    @MainActor
    final class AppContentService {
        static let shared = AppContentService()

        /// Available extractors, in priority order
        private let extractors: [AppExtractor] = [
            TerminalExtractor(),
            CodeEditorExtractor(),
            BrowserExtractor(),
            GenericExtractor() // Fallback
        ]

        private init() {}

        // MARK: - Content Extraction

        /// Extracts content from the specified application.
        /// - Parameter app: The running application to extract content from
        /// - Returns: The extraction result
        func extractContent(from app: NSRunningApplication) async -> AppContentResult {
            // Check accessibility permission
            guard AccessibilityService.shared.checkPermission(prompt: false) else {
                return .permissionDenied
            }

            // Get bundle identifier
            let bundleId = app.bundleIdentifier ?? ""

            // Create AX element for the app
            let appElement = AccessibilityService.shared.createApplicationElement(for: app)

            // Find the appropriate extractor
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

            // Perform extraction
            let result = await extractor.extract(from: app, element: appElement)

            // Log result (without content for privacy)
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

        /// Extracts content from the current frontmost application.
        /// - Returns: The extraction result
        func extractFromFrontmostApp() async -> AppContentResult {
            guard let frontApp = NSWorkspace.shared.frontmostApplication else {
                return .noFocusedApp
            }

            // Don't extract from Ayna itself
            if frontApp.bundleIdentifier == Bundle.main.bundleIdentifier {
                return .noContentAvailable
            }

            return await extractContent(from: frontApp)
        }
    }

    // MARK: - Extractor Protocol

    /// Protocol for app-specific content extractors
    @MainActor
    protocol AppExtractor {
        /// Returns true if this extractor can handle the specified app
        func canHandle(bundleIdentifier: String) -> Bool

        /// Extracts content from the app
        func extract(from app: NSRunningApplication, element: AXUIElement) async -> AppContentResult
    }

    // MARK: - Terminal Extractor

    /// Extracts content from terminal applications with smart command-aware truncation
    struct TerminalExtractor: AppExtractor {
        /// Bundle IDs of terminal applications
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

            // Get window title
            let windowTitle = accessibility.getWindowTitle(in: element)

            // Try to get selected text first (user's explicit selection always takes priority)
            if let focused = accessibility.getFocusedElement(in: element),
               let selectedText = accessibility.getSelectedText(focused),
               !selectedText.isEmpty
            {
                // Even selected text gets smart truncation if very large
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

            // Try to get terminal content from the text area
            if let focused = accessibility.getFocusedElement(in: element),
               let value = accessibility.getValue(focused)
            {
                // Apply smart terminal truncation
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

    // MARK: - Code Editor Extractor

    /// Extracts content from code editors with smart anchor-based truncation
    struct CodeEditorExtractor: AppExtractor {
        /// Bundle ID patterns for code editors
        private let editorPatterns = [
            "com.apple.dt.Xcode",
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92", // Cursor
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

            // Get window title (often contains file path)
            let windowTitle = accessibility.getWindowTitle(in: element)

            // Try to get selected text first (user's explicit selection always takes priority)
            if let focused = accessibility.getFocusedElement(in: element),
               let selectedText = accessibility.getSelectedText(focused),
               !selectedText.isEmpty
            {
                // Selection is usually intentional and sized appropriately, but truncate if huge
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

            // Try to get document content
            if let focused = accessibility.getFocusedElement(in: element),
               let value = accessibility.getValue(focused)
            {
                // Apply smart code truncation with anchors
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

    // MARK: - Browser Extractor

    /// Extracts content from web browsers
    struct BrowserExtractor: AppExtractor {
        /// Bundle ID patterns for browsers
        private let browserPatterns = [
            "com.apple.Safari",
            "com.google.Chrome",
            "company.thebrowser.Browser", // Arc
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

            // Get window title (contains page title)
            let windowTitle = accessibility.getWindowTitle(in: element)

            // Try to get selected text on the page
            if let focused = accessibility.getFocusedElement(in: element),
               let selectedText = accessibility.getSelectedText(focused),
               !selectedText.isEmpty
            {
                // Truncate large selections
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

            // Try to find the URL bar
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

            // If we at least have a window title, use that
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

        /// Attempts to find the URL from a browser's address bar
        private func findURLFromBrowser(element: AXUIElement) async -> String? {
            // Try to find an element with role "AXTextField" or "AXComboBox" that contains a URL
            // This is a simplified approach; browsers vary in their AX hierarchy
            var result: String?

            // Try focused element first
            if let focused = AccessibilityService.shared.getFocusedElement(in: element) {
                if let value = AccessibilityService.shared.getValue(focused) {
                    // Check if it looks like a URL
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

    // MARK: - Generic Extractor

    /// Fallback extractor for any application
    struct GenericExtractor: AppExtractor {
        func canHandle(bundleIdentifier _: String) -> Bool {
            // Always returns true as fallback
            true
        }

        func extract(from app: NSRunningApplication, element: AXUIElement) async -> AppContentResult {
            let accessibility = AccessibilityService.shared

            // Get window title
            let windowTitle = accessibility.getWindowTitle(in: element)

            // Try to get selected text from focused element
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

            // Try to get value from focused element
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

            // If we only have a window title, report it
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
