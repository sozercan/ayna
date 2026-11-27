#if os(macOS)
    import AppKit

    @MainActor
    struct AppContent {
        let appName: String

        let appIcon: NSImage?

        let bundleIdentifier: String?

        let windowTitle: String?

        let content: String

        let contentType: ContentType

        let isTruncated: Bool

        let originalLength: Int

        enum ContentType: String, Sendable {
            case selectedText
            case documentContent
            case terminalOutput
            case browserURL
            case generic

            var displayName: String {
                switch self {
                case .selectedText: "Selected Text"
                case .documentContent: "Document"
                case .terminalOutput: "Terminal Output"
                case .browserURL: "Web Page"
                case .generic: "Content"
                }
            }
        }

        static func hasSamePayload(_ lhs: AppContent?, _ rhs: AppContent?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil):
                true
            case let (lhs?, rhs?):
                lhs.appName == rhs.appName &&
                    lhs.bundleIdentifier == rhs.bundleIdentifier &&
                    lhs.windowTitle == rhs.windowTitle &&
                    lhs.content == rhs.content &&
                    lhs.contentType == rhs.contentType &&
                    lhs.isTruncated == rhs.isTruncated &&
                    lhs.originalLength == rhs.originalLength
            default:
                false
            }
        }

        func truncated(to maxLength: Int, addIndicator: Bool = true) -> AppContent {
            guard content.count > maxLength else {
                return self
            }

            let truncatedContent: String

            if contentType == .terminalOutput {
                if addIndicator {
                    let omitted = content.count - maxLength
                    truncatedContent = "[... \(omitted) earlier characters omitted ...]\n\n" + String(content.suffix(maxLength))
                } else {
                    truncatedContent = String(content.suffix(maxLength))
                }
            } else {
                if addIndicator {
                    let remaining = content.count - maxLength
                    truncatedContent = String(content.prefix(maxLength)) + "\n\n[Content truncated — \(remaining) more characters]"
                } else {
                    truncatedContent = String(content.prefix(maxLength))
                }
            }

            return AppContent(
                appName: appName,
                appIcon: appIcon,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                content: truncatedContent,
                contentType: contentType,
                isTruncated: true,
                originalLength: originalLength
            )
        }
    }

    @MainActor
    enum AppContentResult {
        case success(AppContent)

        case permissionDenied

        case noFocusedApp

        case noContentAvailable

        case extractionFailed(reason: String)

        var content: AppContent? {
            if case let .success(content) = self {
                return content
            }
            return nil
        }

        var isSuccess: Bool {
            if case .success = self {
                return true
            }
            return false
        }

        var errorMessage: String? {
            switch self {
            case .success:
                nil
            case .permissionDenied:
                "Accessibility permission is required to capture content from other apps."
            case .noFocusedApp:
                "No application is currently focused."
            case .noContentAvailable:
                "No content could be extracted from the focused app."
            case let .extractionFailed(reason):
                "Failed to extract content: \(reason)"
            }
        }
    }

    extension AppContent {
        static let modelCharacterLimit = 16000

        static let previewCharacterLimit = 500

        var forModel: AppContent {
            truncated(to: Self.modelCharacterLimit, addIndicator: true)
        }

        var forPreview: AppContent {
            truncated(to: Self.previewCharacterLimit, addIndicator: true)
        }
    }

    extension AppContent {
        private static let secretPatterns: [String] = [
            #"(?i)(api[_-]?key|secret|password|token|credential)\s*[:=]\s*\S+"#,
            #"sk-[a-zA-Z0-9]{32,}"#,
            #"ghp_[a-zA-Z0-9]{36}"#,
            #"gho_[a-zA-Z0-9]{36}"#,
            #"github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}"#,
            #"xoxb-[0-9]+-[0-9]+-[a-zA-Z0-9]+"#,
            #"xoxp-[0-9]+-[0-9]+-[0-9]+-[a-f0-9]+"#,
            #"AKIA[0-9A-Z]{16}"#,
            #"(?i)bearer\s+[a-zA-Z0-9\-._~+/]+=*"#
        ]

        private static let compiledPatterns: [NSRegularExpression] = secretPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }

        var redacted: AppContent {
            var redactedContent = content

            for regex in Self.compiledPatterns {
                let range = NSRange(redactedContent.startIndex..., in: redactedContent)
                redactedContent = regex.stringByReplacingMatches(
                    in: redactedContent,
                    options: [],
                    range: range,
                    withTemplate: "[REDACTED]"
                )
            }

            return AppContent(
                appName: appName,
                appIcon: appIcon,
                bundleIdentifier: bundleIdentifier,
                windowTitle: windowTitle,
                content: redactedContent,
                contentType: contentType,
                isTruncated: isTruncated,
                originalLength: originalLength
            )
        }
    }
#endif
