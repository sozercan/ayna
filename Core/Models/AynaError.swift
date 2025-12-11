//
//  AynaError.swift
//  ayna
//
//  Unified error types for consistent error handling across the app.
//  This provides a centralized error taxonomy with user-friendly messages.
//

import Foundation

// MARK: - Unified Error Type

/// Unified error enum covering all failure modes in the Ayna app
///
/// Use this type for new error handling. Existing service-specific errors
/// (OpenAIError, TavilyError, etc.) are preserved for backward compatibility
/// and can be wrapped in AynaError cases.
enum AynaError: LocalizedError, Sendable {
    // MARK: - Network & Connectivity

    /// Network request failed (timeout, no connection, etc.)
    case networkError(underlying: Error)

    /// Server returned an unexpected HTTP status
    case httpError(statusCode: Int, message: String?)

    /// Request timed out
    case timeout

    /// Rate limit exceeded
    case rateLimited(retryAfter: TimeInterval?)

    // MARK: - Authentication & Configuration

    /// API key is missing or not configured
    case missingAPIKey(provider: String)

    /// API key is invalid or expired
    case invalidAPIKey(provider: String)

    /// Required configuration is missing
    case missingConfiguration(detail: String)

    /// OAuth authentication failed
    case authenticationFailed(reason: String)

    // MARK: - Model & Provider

    /// No model is selected or available
    case noModelSelected

    /// Model not found or unavailable
    case modelNotFound(modelName: String)

    /// Provider is not supported for this operation
    case unsupportedProvider(provider: String, operation: String)

    /// Model capability mismatch (e.g., using image model for chat)
    case capabilityMismatch(expected: String, actual: String)

    // MARK: - API Response

    /// API returned an invalid or malformed response
    case invalidResponse(detail: String?)

    /// Content was filtered by the API's safety systems
    case contentFiltered(reason: String)

    /// API returned an error message
    case apiError(message: String)

    // MARK: - Tool Execution

    /// Tool not found
    case toolNotFound(toolName: String)

    /// Tool execution failed
    case toolExecutionFailed(toolName: String, reason: String)

    /// Tool chain exceeded maximum depth
    case toolChainDepthExceeded(maxDepth: Int)

    // MARK: - Data & Storage

    /// Failed to encode data
    case encodingFailed(detail: String)

    /// Failed to decode data
    case decodingFailed(detail: String)

    /// File operation failed
    case fileOperationFailed(operation: String, path: String?)

    /// Keychain operation failed
    case keychainError(operation: String, status: OSStatus?)

    // MARK: - Conversation

    /// Conversation not found
    case conversationNotFound(id: UUID)

    /// Message not found
    case messageNotFound(id: UUID)

    // MARK: - Generic

    /// Operation was cancelled
    case cancelled

    /// Unknown error with optional underlying cause
    case unknown(message: String, underlying: Error?)

    // MARK: - LocalizedError Conformance

    var errorDescription: String? {
        switch self {
        // Network
        case let .networkError(underlying):
            return "Network error: \(underlying.localizedDescription)"
        case let .httpError(statusCode, message):
            if let message {
                return message
            }
            return "Server error (HTTP \(statusCode))"
        case .timeout:
            return "Request timed out"
        case .rateLimited:
            return "Rate limit exceeded. Please wait before trying again."

        // Authentication
        case let .missingAPIKey(provider):
            return "\(provider) API key not configured"
        case let .invalidAPIKey(provider):
            return "Invalid \(provider) API key"
        case let .missingConfiguration(detail):
            return "Missing configuration: \(detail)"
        case let .authenticationFailed(reason):
            return "Authentication failed: \(reason)"

        // Model
        case .noModelSelected:
            return "No model selected"
        case let .modelNotFound(modelName):
            return "Model '\(modelName)' not found"
        case let .unsupportedProvider(provider, operation):
            return "\(operation) is not supported for \(provider)"
        case let .capabilityMismatch(expected, actual):
            return "Expected \(expected) model, but got \(actual)"

        // API Response
        case let .invalidResponse(detail):
            if let detail {
                return "Invalid API response: \(detail)"
            }
            return "Invalid response from API"
        case let .contentFiltered(reason):
            return "Content filtered: \(reason)"
        case let .apiError(message):
            return message

        // Tool
        case let .toolNotFound(toolName):
            return "Tool '\(toolName)' not found"
        case let .toolExecutionFailed(toolName, reason):
            return "Tool '\(toolName)' failed: \(reason)"
        case let .toolChainDepthExceeded(maxDepth):
            return "Tool chain exceeded maximum depth of \(maxDepth)"

        // Data
        case let .encodingFailed(detail):
            return "Failed to encode data: \(detail)"
        case let .decodingFailed(detail):
            return "Failed to decode data: \(detail)"
        case let .fileOperationFailed(operation, path):
            if let path {
                return "File \(operation) failed: \(path)"
            }
            return "File \(operation) failed"
        case let .keychainError(operation, status):
            if let status {
                return "Keychain \(operation) failed (status: \(status))"
            }
            return "Keychain \(operation) failed"

        // Conversation
        case .conversationNotFound:
            return "Conversation not found"
        case .messageNotFound:
            return "Message not found"

        // Generic
        case .cancelled:
            return "Operation was cancelled"
        case let .unknown(message, _):
            return message
        }
    }

    var recoverySuggestion: String? {
        switch self {
        // Network
        case .networkError:
            return "Check your internet connection and try again"
        case let .httpError(statusCode, _):
            if statusCode >= 500 {
                return "The server is having issues. Please try again later."
            }
            return "Check your configuration and try again"
        case .timeout:
            return "The request took too long. Try again or use a shorter message."
        case let .rateLimited(retryAfter):
            if let seconds = retryAfter {
                return "Wait \(Int(seconds)) seconds before trying again"
            }
            return "Wait a moment before trying again"

        // Authentication
        case let .missingAPIKey(provider):
            return "Add your \(provider) API key in Settings → Models"
        case let .invalidAPIKey(provider):
            return "Check your \(provider) API key in Settings → Models"
        case .missingConfiguration:
            return "Check Settings to complete configuration"
        case .authenticationFailed:
            return "Try signing in again"

        // Model
        case .noModelSelected:
            return "Select a model in Settings → Models"
        case .modelNotFound:
            return "The model may have been removed. Select a different model."
        case .unsupportedProvider:
            return "Switch to a compatible model"
        case .capabilityMismatch:
            return "Select a model with the right capabilities"

        // API Response
        case .invalidResponse:
            return "Try again. If the issue persists, the API may be having problems."
        case .contentFiltered:
            return "Try rephrasing your message"
        case .apiError:
            return "Check your configuration or try again later"

        // Tool
        case .toolNotFound:
            return "Check that the required tool is configured in Settings → Tools"
        case .toolExecutionFailed:
            return "The tool encountered an error. Try again or use a different approach."
        case .toolChainDepthExceeded:
            return "Simplify your request to reduce tool usage"

        // Data
        case .encodingFailed, .decodingFailed:
            return "The data may be corrupted. Try again with fresh data."
        case .fileOperationFailed:
            return "Check file permissions and disk space"
        case .keychainError:
            return "Check that the app has keychain access"

        // Conversation
        case .conversationNotFound:
            return "The conversation may have been deleted"
        case .messageNotFound:
            return "The message may have been deleted"

        // Generic
        case .cancelled:
            return nil
        case .unknown:
            return "Try again. If the issue persists, restart the app."
        }
    }

    var failureReason: String? {
        errorDescription
    }
}

// MARK: - Error Wrapping

extension AynaError {
    /// Wrap an existing error into an AynaError if not already one
    static func wrap(_ error: Error) -> AynaError {
        // Already an AynaError
        if let aynaError = error as? AynaError {
            return aynaError
        }

        // URL errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost:
                return .networkError(underlying: urlError)
            case .cancelled:
                return .cancelled
            default:
                return .networkError(underlying: urlError)
            }
        }

        // Cancellation
        if error is CancellationError {
            return .cancelled
        }

        // Generic wrap
        return .unknown(message: error.localizedDescription, underlying: error)
    }

    /// Create from HTTP response
    static func fromHTTPResponse(statusCode: Int, data: Data?) -> AynaError {
        var message: String?

        if let data {
            // Try to extract error message from JSON
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? [String: Any],
                   let errorMessage = error["message"] as? String
                {
                    message = errorMessage
                } else if let errorMessage = json["message"] as? String {
                    message = errorMessage
                }
            } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                message = String(text.prefix(200))
            }
        }

        switch statusCode {
        case 401:
            return .invalidAPIKey(provider: "API")
        case 403:
            return .authenticationFailed(reason: message ?? "Access denied")
        case 404:
            return .modelNotFound(modelName: message ?? "unknown")
        case 429:
            return .rateLimited(retryAfter: nil)
        default:
            return .httpError(statusCode: statusCode, message: message)
        }
    }
}

// MARK: - Equatable for Testing

extension AynaError: Equatable {
    static func == (lhs: AynaError, rhs: AynaError) -> Bool {
        switch (lhs, rhs) {
        case (.timeout, .timeout),
             (.noModelSelected, .noModelSelected),
             (.cancelled, .cancelled):
            return true
        case let (.missingAPIKey(lhs), .missingAPIKey(rhs)):
            return lhs == rhs
        case let (.invalidAPIKey(lhs), .invalidAPIKey(rhs)):
            return lhs == rhs
        case let (.modelNotFound(lhs), .modelNotFound(rhs)):
            return lhs == rhs
        case let (.toolNotFound(lhs), .toolNotFound(rhs)):
            return lhs == rhs
        case let (.contentFiltered(lhs), .contentFiltered(rhs)):
            return lhs == rhs
        case let (.apiError(lhs), .apiError(rhs)):
            return lhs == rhs
        case let (.httpError(lCode, lMsg), .httpError(rCode, rMsg)):
            return lCode == rCode && lMsg == rMsg
        case let (.rateLimited(lhs), .rateLimited(rhs)):
            return lhs == rhs
        default:
            // For complex cases with underlying errors, compare descriptions
            return lhs.errorDescription == rhs.errorDescription
        }
    }
}
