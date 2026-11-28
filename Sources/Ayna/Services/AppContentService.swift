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

        private let extractors: [AppExtractor]
        private let checkPermission: () -> Bool
        private let createApplicationElement: (NSRunningApplication) -> AXUIElement
        private let frontmostApplicationProvider: () -> NSRunningApplication?
        private let appBundleIdentifierProvider: (NSRunningApplication) -> String?
        private let ownBundleIdentifierProvider: () -> String?

        init(
            extractors: [AppExtractor] = [
                TerminalExtractor(),
                CodeEditorExtractor(),
                BrowserExtractor(),
                GenericExtractor()
            ],
            checkPermission: @escaping () -> Bool = {
                AccessibilityService.shared.checkPermission(prompt: false)
            },
            createApplicationElement: @escaping (NSRunningApplication) -> AXUIElement = { app in
                AccessibilityService.shared.createApplicationElement(for: app)
            },
            frontmostApplicationProvider: @escaping () -> NSRunningApplication? = {
                NSWorkspace.shared.frontmostApplication
            },
            appBundleIdentifierProvider: @escaping (NSRunningApplication) -> String? = \.bundleIdentifier,
            ownBundleIdentifierProvider: @escaping () -> String? = {
                Bundle.main.bundleIdentifier
            }
        ) {
            self.extractors = extractors
            self.checkPermission = checkPermission
            self.createApplicationElement = createApplicationElement
            self.frontmostApplicationProvider = frontmostApplicationProvider
            self.appBundleIdentifierProvider = appBundleIdentifierProvider
            self.ownBundleIdentifierProvider = ownBundleIdentifierProvider
        }

        func extractContent(from app: NSRunningApplication) async -> AppContentResult {
            guard checkPermission() else {
                return .permissionDenied
            }

            let bundleId = appBundleIdentifierProvider(app) ?? ""

            let appElement = createApplicationElement(app)

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
            guard let frontApp = frontmostApplicationProvider() else {
                return .noFocusedApp
            }

            if let ownBundleId = ownBundleIdentifierProvider(),
               appBundleIdentifierProvider(frontApp) == ownBundleId
            {
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
            let accessibility = AccessibilityService.shared

            if let window = accessibility.getFocusedWindow(in: element) {
                if let documentURL = Self.normalizedBrowserURL(from: accessibility.getDocument(window)) {
                    return documentURL
                }

                if let hierarchyURL = findURLInHierarchy(root: window, accessibility: accessibility) {
                    return hierarchyURL
                }
            }

            if let focused = accessibility.getFocusedElement(in: element) {
                if let documentURL = Self.normalizedBrowserURL(from: accessibility.getDocument(focused)) {
                    return documentURL
                }

                let focusedRole = accessibility.getRole(focused)
                if focusedRole == "AXWebArea",
                   let webAreaURL = Self.normalizedBrowserURL(from: accessibility.getURL(focused))
                {
                    return webAreaURL
                }

                if isAddressBarCandidate(focused, accessibility: accessibility),
                   let valueURL = Self.normalizedBrowserURL(from: accessibility.getValue(focused))
                   ?? Self.normalizedBrowserURL(from: accessibility.getURL(focused))
                {
                    return valueURL
                }
            }

            return nil
        }

        private func findURLInHierarchy(root: AXUIElement, accessibility: AccessibilityService) -> String? {
            let maxDepth = 8
            let maxEnqueuedElements = 300
            var queue: [(element: AXUIElement, depth: Int)] = [(root, 0)]
            var queueIndex = 0
            var addressBarFallback: String?

            while queueIndex < queue.count {
                let current = queue[queueIndex]
                queueIndex += 1

                if current.depth > 0 {
                    let role = accessibility.getRole(current.element)

                    if role == "AXWebArea" {
                        if let webAreaURL = Self.normalizedBrowserURL(from: accessibility.getURL(current.element))
                            ?? Self.normalizedBrowserURL(from: accessibility.getDocument(current.element))
                        {
                            return webAreaURL
                        }
                    }

                    if addressBarFallback == nil,
                       Self.isAddressBarRole(role),
                       Self.isAddressBarDescriptor(
                           identifier: accessibility.getIdentifier(current.element),
                           description: accessibility.getDescription(current.element),
                           title: accessibility.getTitle(current.element),
                           subrole: accessibility.getSubrole(current.element)
                       ),
                       let candidate = Self.normalizedBrowserURL(from: accessibility.getValue(current.element))
                       ?? Self.normalizedBrowserURL(from: accessibility.getURL(current.element))
                    {
                        addressBarFallback = candidate
                    }
                }

                guard current.depth < maxDepth, queue.count < maxEnqueuedElements else { continue }

                let remainingCapacity = maxEnqueuedElements - queue.count
                for child in accessibility.getChildren(current.element).prefix(remainingCapacity) {
                    queue.append((child, current.depth + 1))
                }
            }

            return addressBarFallback
        }

        private func isAddressBarCandidate(_ element: AXUIElement, accessibility: AccessibilityService) -> Bool {
            guard Self.isAddressBarRole(accessibility.getRole(element)) else {
                return false
            }

            return Self.isAddressBarDescriptor(
                identifier: accessibility.getIdentifier(element),
                description: accessibility.getDescription(element),
                title: accessibility.getTitle(element),
                subrole: accessibility.getSubrole(element)
            )
        }

        static func isAddressBarRole(_ role: String?) -> Bool {
            guard let role else { return false }
            return role == (kAXTextFieldRole as String) || role == (kAXComboBoxRole as String)
        }

        static func isAddressBarDescriptor(
            identifier: String?,
            description: String?,
            title: String?,
            subrole: String?
        ) -> Bool {
            let fields = [identifier, description, title, subrole]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            let keywords = [
                "address",
                "url",
                "location",
                "omnibox",
                "webbrowseraddressandsearchfield",
                "urlbar"
            ]

            return fields.contains { field in
                keywords.contains { field.contains($0) }
            }
        }

        static func normalizedBrowserURL(from rawValue: String?) -> String? {
            guard let rawValue else { return nil }

            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            else {
                return nil
            }

            if hasLeadingSchemeSeparator(trimmed) || trimmed.lowercased().hasPrefix("file:") {
                guard let url = URL(string: trimmed),
                      let scheme = url.scheme?.lowercased()
                else {
                    return nil
                }

                if scheme == "http" || scheme == "https" {
                    guard let host = url.host, !host.isEmpty else {
                        return nil
                    }
                    return url.absoluteString
                }

                if scheme == "file" {
                    return url.absoluteString
                }

                return nil
            }

            if hasUnsupportedSchemePrefix(trimmed) {
                return nil
            }

            guard let prefixedURL = URL(string: "https://\(trimmed)"),
                  prefixedURL.user == nil,
                  prefixedURL.password == nil,
                  let host = prefixedURL.host,
                  isValidWebHost(host)
            else {
                return nil
            }

            return prefixedURL.absoluteString
        }

        private static func hasLeadingSchemeSeparator(_ value: String) -> Bool {
            guard let schemeEnd = value.range(of: "://")?.lowerBound else {
                return false
            }
            let prefix = value[..<schemeEnd]
            guard let first = prefix.first, first.isASCII, first.isLetter else {
                return false
            }
            return prefix.allSatisfy { char in
                char.isASCII && (char.isLetter || char.isNumber || char == "+" || char == "-" || char == ".")
            }
        }

        private static func hasUnsupportedSchemePrefix(_ value: String) -> Bool {
            let authorityEnd = value.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? value.endIndex
            let authority = value[..<authorityEnd]

            if authority.hasPrefix("[") {
                guard let closingBracket = authority.firstIndex(of: "]") else {
                    return true
                }
                let afterBracket = authority[authority.index(after: closingBracket)...]
                if afterBracket.isEmpty {
                    return false
                }
                guard afterBracket.hasPrefix(":") else {
                    return true
                }
                let portString = afterBracket.dropFirst()
                guard !portString.isEmpty,
                      portString.allSatisfy(\.isNumber),
                      let port = Int(portString),
                      (1 ... 65535).contains(port)
                else {
                    return true
                }
                return false
            }

            guard let colonIndex = authority.firstIndex(of: ":") else {
                return false
            }

            let afterColon = authority[authority.index(after: colonIndex)...]
            guard !afterColon.isEmpty,
                  afterColon.allSatisfy(\.isNumber),
                  let port = Int(afterColon),
                  (1 ... 65535).contains(port)
            else {
                return true
            }

            return false
        }

        private static func isValidWebHost(_ host: String) -> Bool {
            let lowercased = host.lowercased()
            let normalizedHost = if lowercased.hasSuffix("."), !lowercased.hasSuffix("..") {
                String(lowercased.dropLast())
            } else {
                lowercased
            }

            if normalizedHost == "localhost" {
                return true
            }

            if normalizedHost.contains(":") {
                return true
            }

            guard normalizedHost.contains("."),
                  !normalizedHost.hasPrefix("."),
                  !normalizedHost.hasSuffix("."),
                  !normalizedHost.contains("..")
            else {
                return false
            }

            let labels = normalizedHost.split(separator: ".")
            if labels.count == 4, labels.allSatisfy({ Int($0).map { (0 ... 255).contains($0) } ?? false }) {
                return true
            }

            guard labels.count >= 2,
                  let tld = labels.last,
                  isValidTLD(tld)
            else {
                return false
            }

            return labels.allSatisfy { label in
                !label.isEmpty &&
                    !label.hasPrefix("-") &&
                    !label.hasSuffix("-") &&
                    label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            }
        }

        private static func isValidTLD(_ tld: Substring) -> Bool {
            if tld.count >= 2, tld.allSatisfy(\.isLetter) {
                return true
            }
            if tld.hasPrefix("xn--"),
               tld.count > 4,
               !tld.hasSuffix("-"),
               tld.dropFirst(4).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            {
                return true
            }
            return false
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
