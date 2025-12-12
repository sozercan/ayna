//
//  DiagnosticsLogger.swift
//  ayna
//
//  Created on 11/14/25.
//

import Foundation
import os.log

enum DiagnosticsCategory: String, CaseIterable, Codable {
    case app = "App"
    case openAIService = "OpenAIService"
    case mcpServerManager = "MCPServerManager"
    case mcpService = "MCPService"
    case aiKitService = "AIKitService"
    case appleIntelligence = "AppleIntelligenceService"
    case encryptedStore = "EncryptedConversationStore"
    case keychain = "KeychainStorage"
    case conversationManager = "ConversationManager"
    case chatView = "ChatView"
    case contentView = "ContentView"
    case attachmentStorage = "AttachmentStorage"
    case watchConnectivity = "WatchConnectivity"
    case attachFromApp = "AttachFromApp"
}

enum BreadcrumbLevel: String, Codable {
    case debug
    case info
    case notice
    case warning
    case error
    case fault
}

struct Breadcrumb: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticsCategory
    let level: BreadcrumbLevel
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: DiagnosticsCategory,
        level: BreadcrumbLevel,
        message: String,
        metadata: [String: String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.message = message
        self.metadata = metadata
    }
}

final class BreadcrumbStore: @unchecked Sendable {
    static let shared = BreadcrumbStore()

    private let maxEntries = 200
    private let queue = DispatchQueue(label: "com.sertacozercan.ayna.breadcrumbs", qos: .utility)
    private let storageURL: URL
    private var entries: [Breadcrumb] = []

    private init(fileManager: FileManager = .default) {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = appSupport.appendingPathComponent("Ayna", isDirectory: true)

        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        storageURL = directory.appendingPathComponent("breadcrumbs.json")

        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([Breadcrumb].self, from: data)
        {
            entries = Array(decoded.suffix(maxEntries))
        }
    }

    func record(
        category: DiagnosticsCategory,
        level: BreadcrumbLevel,
        message: String,
        metadata: [String: String]
    ) {
        queue.async {
            let breadcrumb = Breadcrumb(category: category, level: level, message: message, metadata: metadata)
            self.entries.append(breadcrumb)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            self.persistLocked()
        }
    }

    func latest(limit: Int? = nil) -> [Breadcrumb] {
        queue.sync {
            let snapshot = entries
            if let limit, limit < snapshot.count {
                return Array(snapshot.suffix(limit))
            }
            return snapshot
        }
    }

    private func persistLocked() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            os_log("Failed to persist breadcrumbs: %{public}@", log: .default, type: .error, error.localizedDescription)
        }
    }
}

enum DiagnosticsLogger {
    private static let subsystem = "com.sertacozercan.ayna"
    private static let loggers: [DiagnosticsCategory: Logger] = {
        var dictionary: [DiagnosticsCategory: Logger] = [:]
        for category in DiagnosticsCategory.allCases {
            dictionary[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        return dictionary
    }()

    static func log(
        _ category: DiagnosticsCategory,
        level: OSLogType = .default,
        message: String,
        metadata: [String: String] = [:]
    ) {
        guard let logger = loggers[category] else { return }

        if metadata.isEmpty {
            logger.log(level: level, "\(message, privacy: .public)")
        } else {
            let metaString = metadata
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            logger.log(level: level, "\(message, privacy: .public) [\(metaString, privacy: .public)]")
        }

        BreadcrumbStore.shared.record(
            category: category,
            level: level.breadcrumbLevel,
            message: message,
            metadata: metadata
        )
    }
}

private extension OSLogType {
    var breadcrumbLevel: BreadcrumbLevel {
        switch self {
        case .debug:
            .debug
        case .info:
            .info
        case .default:
            .notice
        case .error:
            .error
        case .fault:
            .fault
        default:
            .notice
        }
    }
}

// MARK: - ErrorPresenter

/// Converts low-level errors into user-facing messages.
///
/// Important: Never include secrets (API keys/tokens) in returned strings.
enum ErrorPresenter {
    // MARK: - Public API

    static func userMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return sanitizeUserFacingMessage(description)
        }

        if let urlError = error as? URLError {
            return sanitizeUserFacingMessage(userMessage(for: urlError))
        }

        return sanitizeUserFacingMessage(error.localizedDescription)
    }

    static func recoverySuggestion(for error: Error) -> String? {
        if let localizedError = error as? LocalizedError {
            if let suggestion = localizedError.recoverySuggestion {
                return suggestion
            }

            let message = userMessage(for: error)
            if isLikelyInvalidAPIKey(message) {
                return "Check your API key in Settings → Models"
            }

            return nil
        }

        if let urlError = error as? URLError {
            return recoverySuggestion(for: urlError)
        }

        return nil
    }

    static func category(for error: Error) -> ErrorCategory {
        if error is CancellationError {
            return .cancelled
        }

        if error is URLError {
            return .network
        }

        let message = userMessage(for: error).lowercased()

        if message.contains("api key") || message.contains("authentication") {
            return .authentication
        }

        if message.contains("no model selected") || message.contains("model '") || message.contains("missing configuration") {
            return .configuration
        }

        if message.contains("invalid response") || message.contains("content filtered") || message.contains("server error") {
            return .api
        }

        if message.contains("tool '") || message.contains("tool chain") {
            return .tool
        }

        if message.contains("encode") || message.contains("decode") || message.contains("keychain") || message.contains("file ") {
            return .data
        }

        if message.contains("conversation not found") || message.contains("message not found") {
            return .conversation
        }

        if message.contains("network") || message.contains("internet") || message.contains("timed out") {
            return .network
        }

        return .unknown
    }

    static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost:
                return true
            default:
                return false
            }
        }

        let message = userMessage(for: error).lowercased()
        return message.contains("timed out") || message.contains("try again") || message.contains("network")
    }

    static func requiresUserAction(_ error: Error) -> Bool {
        let message = userMessage(for: error).lowercased()
        return message.contains("api key") || message.contains("missing configuration") || message.contains("no model selected")
    }

    static func suggestedAction(for error: Error) -> ErrorAction {
        if isRetryable(error) {
            return .retry
        }

        if requiresUserAction(error) {
            return .openSettings
        }

        if error is CancellationError {
            return .dismiss
        }

        return .dismiss
    }

    static func logError(
        _ error: Error,
        context: String,
        category: DiagnosticsCategory = .app
    ) {
        let message = userMessage(for: error)
        let errorCategory = self.category(for: error)

        var metadata: [String: String] = [
            "context": context,
            "category": errorCategory.rawValue,
        ]

        if let recovery = recoverySuggestion(for: error) {
            metadata["recovery"] = recovery
        }

        DiagnosticsLogger.log(
            category,
            level: errorCategory == .cancelled ? .info : .error,
            message: "❌ \(message)",
            metadata: metadata
        )
    }

    enum ErrorCategory: String, Sendable {
        case network
        case authentication
        case configuration
        case api
        case tool
        case data
        case conversation
        case cancelled
        case unknown
    }

    enum ErrorAction {
        case retry
        case openSettings
        case dismiss
    }

    // MARK: - URLError Handling

    private static func userMessage(for urlError: URLError) -> String {
        switch urlError.code {
        case .timedOut:
            return "The request timed out"
        case .notConnectedToInternet:
            return "No internet connection"
        case .networkConnectionLost:
            return "Network connection was lost"
        case .cannotFindHost:
            return "Could not find the server"
        case .cannotConnectToHost:
            return "Could not connect to the server"
        case .secureConnectionFailed:
            return "Secure connection failed"
        case .cancelled:
            return "Request was cancelled"
        default:
            return "Network error occurred"
        }
    }

    private static func recoverySuggestion(for urlError: URLError) -> String? {
        switch urlError.code {
        case .timedOut:
            return "Try again or use a shorter message"
        case .notConnectedToInternet:
            return "Check your internet connection"
        case .networkConnectionLost:
            return "Check your connection and try again"
        case .cannotFindHost, .cannotConnectToHost:
            return "Check the server URL in Settings"
        case .secureConnectionFailed:
            return "The server's security certificate may be invalid"
        case .cancelled:
            return nil
        default:
            return "Try again in a moment"
        }
    }

    // MARK: - AynaError Categorization

    // Note: AynaError is not part of all app targets today, so we avoid
    // directly referencing it here and use heuristics based on message text.

    // MARK: - Sanitization

    private static func sanitizeUserFacingMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "An unexpected error occurred" }

        // OpenAI invalid-key errors can include part of the key.
        let lower = trimmed.lowercased()
        if lower.contains("incorrect api key provided") || lower.contains("invalid api key") {
            return "Invalid API key"
        }

        // Redact common token formats if they appear.
        var redacted = trimmed
        redacted = redact(pattern: #"sk-(?:proj-)?[A-Za-z0-9]{16,}"#, in: redacted, replacement: "[REDACTED_API_KEY]")
        redacted = redact(pattern: #"ghp_[A-Za-z0-9]{20,}"#, in: redacted, replacement: "[REDACTED_TOKEN]")
        redacted = redact(pattern: #"(?i)bearer\s+[A-Za-z0-9._\-]+"#, in: redacted, replacement: "Bearer [REDACTED_TOKEN]")

        // If it's mostly a help-text wall, keep it short.
        if redacted.lowercased().contains("platform.openai.com/account/api-keys") {
            return "Invalid API key"
        }

        return redacted
    }

    private static func redact(pattern: String, in text: String, replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }

    private static func isLikelyInvalidAPIKey(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower == "invalid api key" || lower.contains("invalid api key") || lower.contains("api key not configured")
    }
}
