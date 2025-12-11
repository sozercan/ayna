//
//  ErrorPresenter.swift
//  ayna
//
//  Utility for presenting errors to users with consistent, friendly messaging.
//

import Foundation

/// Utility for presenting errors to users
enum ErrorPresenter {
    // MARK: - User-Friendly Message Conversion

    /// Convert any error to a user-friendly message
    static func userMessage(for error: Error) -> String {
        // If it's already an AynaError, use its description
        if let aynaError = error as? AynaError {
            return aynaError.errorDescription ?? "An unexpected error occurred"
        }

        // Handle LocalizedError types (OpenAIError, TavilyError, etc.)
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }

        // Handle URL errors with friendly messages
        if let urlError = error as? URLError {
            return userMessage(for: urlError)
        }

        // Default to localized description
        return error.localizedDescription
    }

    /// Get recovery suggestion for any error
    static func recoverySuggestion(for error: Error) -> String? {
        // AynaError
        if let aynaError = error as? AynaError {
            return aynaError.recoverySuggestion
        }

        // LocalizedError
        if let localizedError = error as? LocalizedError {
            return localizedError.recoverySuggestion
        }

        // URL errors
        if let urlError = error as? URLError {
            return recoverySuggestion(for: urlError)
        }

        return nil
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

    // MARK: - Error Categorization

    /// Categorize an error for logging and analytics
    static func category(for error: Error) -> ErrorCategory {
        if let aynaError = error as? AynaError {
            return category(for: aynaError)
        }

        if error is URLError || error is CancellationError {
            return .network
        }

        return .unknown
    }

    private static func category(for error: AynaError) -> ErrorCategory {
        switch error {
        case .networkError, .httpError, .timeout, .rateLimited:
            return .network
        case .missingAPIKey, .invalidAPIKey, .authenticationFailed:
            return .authentication
        case .missingConfiguration, .noModelSelected, .modelNotFound,
             .unsupportedProvider, .capabilityMismatch:
            return .configuration
        case .invalidResponse, .contentFiltered, .apiError:
            return .api
        case .toolNotFound, .toolExecutionFailed, .toolChainDepthExceeded:
            return .tool
        case .encodingFailed, .decodingFailed, .fileOperationFailed, .keychainError:
            return .data
        case .conversationNotFound, .messageNotFound:
            return .conversation
        case .cancelled:
            return .cancelled
        case .unknown:
            return .unknown
        }
    }

    /// Error categories for logging and analytics
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

    // MARK: - Logging Support

    /// Log an error with appropriate level and context
    static func logError(
        _ error: Error,
        context: String,
        subsystem: DiagnosticsLogger.Subsystem = .app
    ) {
        let message = userMessage(for: error)
        let category = self.category(for: error)

        var metadata: [String: String] = [
            "context": context,
            "category": category.rawValue,
        ]

        if let recovery = recoverySuggestion(for: error) {
            metadata["recovery"] = recovery
        }

        DiagnosticsLogger.log(
            subsystem,
            level: category == .cancelled ? .info : .error,
            message: "❌ \(message)",
            metadata: metadata
        )
    }

    // MARK: - Error Action Determination

    /// Determine if an error is recoverable by retrying
    static func isRetryable(_ error: Error) -> Bool {
        if let aynaError = error as? AynaError {
            switch aynaError {
            case .networkError, .timeout, .rateLimited,
                 .httpError(statusCode: let code, _) where code >= 500:
                return true
            default:
                return false
            }
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost:
                return true
            default:
                return false
            }
        }

        return false
    }

    /// Determine if an error requires user action (like configuration)
    static func requiresUserAction(_ error: Error) -> Bool {
        if let aynaError = error as? AynaError {
            switch aynaError {
            case .missingAPIKey, .invalidAPIKey, .missingConfiguration,
                 .noModelSelected, .modelNotFound:
                return true
            default:
                return false
            }
        }

        return false
    }

    /// Determine the appropriate action for the user
    static func suggestedAction(for error: Error) -> ErrorAction {
        if isRetryable(error) {
            return .retry
        }

        if requiresUserAction(error) {
            return .openSettings
        }

        if let aynaError = error as? AynaError, case .cancelled = aynaError {
            return .dismiss
        }

        return .dismiss
    }

    /// Suggested user actions
    enum ErrorAction {
        case retry
        case openSettings
        case dismiss
    }
}
