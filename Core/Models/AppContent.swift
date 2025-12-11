//
//  AppContent.swift
//  ayna
//
//  Data structures for extracted content from applications.
//

#if os(macOS)
    import AppKit

    /// Represents content extracted from a focused application.
    /// Note: Uses @unchecked Sendable because NSImage isn't Sendable, but this struct
    /// is only created and used on MainActor in practice. The appIcon is purely for display.
    struct AppContent: @unchecked Sendable {
        /// The display name of the application
        let appName: String

        /// The application's icon
        let appIcon: NSImage?

        /// The application's bundle identifier
        let bundleIdentifier: String?

        /// The title of the focused window
        let windowTitle: String?

        /// The extracted content text
        let content: String

        /// The type/source of the extracted content
        let contentType: ContentType

        /// Whether the content was truncated due to size limits
        let isTruncated: Bool

        /// The original length of the content before truncation
        let originalLength: Int

        /// Types of content that can be extracted
        enum ContentType: String, Sendable {
            /// User-selected text
            case selectedText
            /// Full document content (e.g., from code editors)
            case documentContent
            /// Terminal/console output
            case terminalOutput
            /// URL from a browser
            case browserURL
            /// Generic content (fallback)
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

        /// Creates a truncated version of this content.
        /// For terminal output, keeps the END (most recent output).
        /// For other content types, keeps the START.
        /// - Parameters:
        ///   - maxLength: Maximum character length
        ///   - addIndicator: Whether to add truncation indicator
        /// - Returns: A new AppContent with truncated text if needed
        func truncated(to maxLength: Int, addIndicator: Bool = true) -> AppContent {
            guard content.count > maxLength else {
                return self
            }

            let truncatedContent: String

            // For terminal output, keep the END (most recent output)
            if contentType == .terminalOutput {
                if addIndicator {
                    let omitted = content.count - maxLength
                    truncatedContent = "[... \(omitted) earlier characters omitted ...]\n\n" + String(content.suffix(maxLength))
                } else {
                    truncatedContent = String(content.suffix(maxLength))
                }
            } else {
                // For other content types, keep the START
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

    /// Result of attempting to extract content from an application.
    enum AppContentResult: Sendable {
        /// Successfully extracted content
        case success(AppContent)

        /// Accessibility permission is not granted
        case permissionDenied

        /// No application is focused
        case noFocusedApp

        /// The focused app has no extractable content
        case noContentAvailable

        /// Content extraction failed for a specific reason
        case extractionFailed(reason: String)

        /// Returns the extracted content if successful
        var content: AppContent? {
            if case let .success(content) = self {
                return content
            }
            return nil
        }

        /// Returns true if extraction was successful
        var isSuccess: Bool {
            if case .success = self {
                return true
            }
            return false
        }

        /// Returns a user-friendly error message
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

    // MARK: - Content Size Limits

    extension AppContent {
        /// Maximum characters to send to the AI model (~4000 tokens)
        static let modelCharacterLimit = 16000

        /// Maximum characters to display in the preview UI
        static let previewCharacterLimit = 500

        /// Creates a version suitable for the AI model (truncated to model limit)
        var forModel: AppContent {
            truncated(to: Self.modelCharacterLimit, addIndicator: true)
        }

        /// Creates a version suitable for UI preview (truncated to preview limit)
        var forPreview: AppContent {
            truncated(to: Self.previewCharacterLimit, addIndicator: true)
        }
    }

    // MARK: - Secret Redaction

    extension AppContent {
        /// Patterns that might indicate secrets or sensitive data
        private static let secretPatterns: [String] = [
            #"(?i)(api[_-]?key|secret|password|token|credential)\s*[:=]\s*\S+"#,
            #"sk-[a-zA-Z0-9]{32,}"#, // OpenAI keys
            #"ghp_[a-zA-Z0-9]{36}"#, // GitHub tokens
            #"gho_[a-zA-Z0-9]{36}"#, // GitHub OAuth tokens
            #"github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}"#, // GitHub PATs
            #"xoxb-[0-9]+-[0-9]+-[a-zA-Z0-9]+"#, // Slack bot tokens
            #"xoxp-[0-9]+-[0-9]+-[0-9]+-[a-f0-9]+"#, // Slack user tokens
            #"AKIA[0-9A-Z]{16}"#, // AWS access keys
            #"(?i)bearer\s+[a-zA-Z0-9\-._~+/]+=*"# // Bearer tokens
        ]

        /// Pre-compiled regex patterns for better performance
        private static let compiledPatterns: [NSRegularExpression] = secretPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: []) }

        /// Returns content with potential secrets redacted
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
