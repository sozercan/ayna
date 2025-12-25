//
//  AynaErrorTests.swift
//  aynaTests
//
//  Unit tests for AynaError and ErrorPresenter.
//

import Foundation
import Testing

@testable import Ayna

@Suite("AynaError Tests")
struct AynaErrorTests {
    // MARK: - Error Description Tests

    @Test("Network error has correct description")
    func networkErrorDescription() {
        let urlError = URLError(.notConnectedToInternet)
        let error = AynaError.networkError(underlying: urlError)

        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("Network error") == true)
    }

    @Test("Timeout error has correct description")
    func timeoutErrorDescription() {
        let error = AynaError.timeout

        #expect(error.errorDescription == "Request timed out")
        #expect(error.recoverySuggestion != nil)
    }

    @Test("Missing API key error has correct description")
    func missingAPIKeyErrorDescription() {
        let error = AynaError.missingAPIKey(provider: "OpenAI")

        #expect(error.errorDescription == "OpenAI API key not configured")
        #expect(error.recoverySuggestion?.contains("Settings") == true)
    }

    @Test("Invalid API key error has correct description")
    func invalidAPIKeyErrorDescription() {
        let error = AynaError.invalidAPIKey(provider: "GitHub")

        #expect(error.errorDescription == "Invalid GitHub API key")
    }

    @Test("No model selected error has correct description")
    func noModelSelectedErrorDescription() {
        let error = AynaError.noModelSelected

        #expect(error.errorDescription == "No model selected")
        #expect(error.recoverySuggestion?.contains("Settings") == true)
    }

    @Test("Model not found error has correct description")
    func modelNotFoundErrorDescription() {
        let error = AynaError.modelNotFound(modelName: "gpt-5")

        #expect(error.errorDescription == "Model 'gpt-5' not found")
    }

    @Test("Content filtered error has correct description")
    func contentFilteredErrorDescription() {
        let error = AynaError.contentFiltered(reason: "Inappropriate content")

        #expect(error.errorDescription?.contains("Content filtered") == true)
        #expect(error.recoverySuggestion == "Try rephrasing your message")
    }

    @Test("Tool not found error has correct description")
    func toolNotFoundErrorDescription() {
        let error = AynaError.toolNotFound(toolName: "web_search")

        #expect(error.errorDescription == "Tool 'web_search' not found")
    }

    @Test("Tool execution failed error has correct description")
    func toolExecutionFailedErrorDescription() {
        let error = AynaError.toolExecutionFailed(toolName: "calculator", reason: "Division by zero")

        #expect(error.errorDescription?.contains("calculator") == true)
        #expect(error.errorDescription?.contains("Division by zero") == true)
    }

    @Test("Rate limited error has correct description")
    func rateLimitedErrorDescription() {
        let error = AynaError.rateLimited(retryAfter: 60)

        #expect(error.errorDescription?.contains("Rate limit") == true)
        #expect(error.recoverySuggestion?.contains("60") == true)
    }

    @Test("Cancelled error has correct description")
    func cancelledErrorDescription() {
        let error = AynaError.cancelled

        #expect(error.errorDescription == "Operation was cancelled")
        #expect(error.recoverySuggestion == nil)
    }

    // MARK: - Error Wrapping Tests

    @Test("Wrap URLError timeout returns timeout error")
    func wrapURLErrorTimeout() {
        let urlError = URLError(.timedOut)
        let wrapped = AynaError.wrap(urlError)

        #expect(wrapped == .timeout)
    }

    @Test("Wrap URLError no connection returns network error")
    func wrapURLErrorNoConnection() {
        let urlError = URLError(.notConnectedToInternet)
        let wrapped = AynaError.wrap(urlError)

        if case .networkError = wrapped {
            // Pass
        } else {
            Issue.record("Expected networkError")
        }
    }

    @Test("Wrap URLError cancelled returns cancelled error")
    func wrapURLErrorCancelled() {
        let urlError = URLError(.cancelled)
        let wrapped = AynaError.wrap(urlError)

        #expect(wrapped == .cancelled)
    }

    @Test("Wrap CancellationError returns cancelled error")
    func wrapCancellationError() {
        let error = CancellationError()
        let wrapped = AynaError.wrap(error)

        #expect(wrapped == .cancelled)
    }

    @Test("Wrap AynaError passes through")
    func wrapAynaErrorPassthrough() {
        let original = AynaError.timeout
        let wrapped = AynaError.wrap(original)

        #expect(wrapped == .timeout)
    }

    @Test("Wrap unknown error returns unknown error")
    func wrapUnknownError() {
        struct CustomError: Error {}
        let error = CustomError()
        let wrapped = AynaError.wrap(error)

        if case .unknown = wrapped {
            // Pass
        } else {
            Issue.record("Expected unknown error")
        }
    }

    // MARK: - HTTP Response Conversion Tests

    @Test("HTTP response 401 returns invalid API key error")
    func fromHTTPResponse401() {
        let error = AynaError.fromHTTPResponse(statusCode: 401, data: nil)

        if case let .invalidAPIKey(provider) = error {
            #expect(provider == "API")
        } else {
            Issue.record("Expected invalidAPIKey")
        }
    }

    @Test("HTTP response 429 returns rate limited error")
    func fromHTTPResponse429() {
        let error = AynaError.fromHTTPResponse(statusCode: 429, data: nil)

        if case .rateLimited = error {
            // Pass
        } else {
            Issue.record("Expected rateLimited")
        }
    }

    @Test("HTTP response 500 with JSON error parses message")
    func fromHTTPResponse500WithJSONError() {
        let json = Data("""
        {"error": {"message": "Internal server error"}}
        """.utf8)

        let error = AynaError.fromHTTPResponse(statusCode: 500, data: json)

        if case let .httpError(statusCode, message) = error {
            #expect(statusCode == 500)
            #expect(message == "Internal server error")
        } else {
            Issue.record("Expected httpError")
        }
    }

    // MARK: - Equatable Tests

    @Test("Simple error cases are equatable")
    func equatableSimpleCases() {
        #expect(AynaError.timeout == AynaError.timeout)
        #expect(AynaError.noModelSelected == AynaError.noModelSelected)
        #expect(AynaError.cancelled == AynaError.cancelled)
    }

    @Test("Errors with parameters are equatable")
    func equatableWithParameters() {
        #expect(
            AynaError.missingAPIKey(provider: "OpenAI") ==
                AynaError.missingAPIKey(provider: "OpenAI")
        )
        #expect(
            AynaError.missingAPIKey(provider: "OpenAI") !=
                AynaError.missingAPIKey(provider: "Azure")
        )
    }

    @Test("HTTP errors are equatable")
    func equatableHTTPError() {
        #expect(
            AynaError.httpError(statusCode: 500, message: "Error") ==
                AynaError.httpError(statusCode: 500, message: "Error")
        )
        #expect(
            AynaError.httpError(statusCode: 500, message: "Error") !=
                AynaError.httpError(statusCode: 404, message: "Error")
        )
    }
}

// MARK: - ErrorPresenter Tests

@Suite("ErrorPresenter Tests")
struct ErrorPresenterTests {
    @Test("User message for AynaError")
    func userMessageForAynaError() {
        let error = AynaError.timeout
        let message = ErrorPresenter.userMessage(for: error)

        #expect(message == "Request timed out")
    }

    @Test("User message for URLError")
    func userMessageForURLError() {
        let error = URLError(.notConnectedToInternet)
        let message = ErrorPresenter.userMessage(for: error)

        #expect(message == "No internet connection")
    }

    @Test("User message sanitizes incorrect API key message")
    func userMessageSanitizesIncorrectAPIKeyMessage() {
        let leakingMessage = "Incorrect API key provided: sk-proj-1234567890ABCDEFGH. You can find your API key at https://platform.openai.com/account/api-keys."
        let error = OpenAIService.OpenAIError.apiError(leakingMessage)

        let message = ErrorPresenter.userMessage(for: error)

        #expect(message == "Invalid API key")
        #expect(!message.contains("sk-proj-"))
        #expect(!message.contains("platform.openai.com"))
    }

    @Test("Recovery suggestion for AynaError")
    func recoverySuggestionForAynaError() {
        let error = AynaError.missingAPIKey(provider: "OpenAI")
        let suggestion = ErrorPresenter.recoverySuggestion(for: error)

        #expect(suggestion != nil)
        #expect(suggestion?.contains("Settings") == true)
    }

    @Test("Category for network error")
    func categoryForNetworkError() {
        let error = AynaError.networkError(underlying: URLError(.timedOut))
        let category = ErrorPresenter.category(for: error)

        #expect(category == .network)
    }

    @Test("Category for auth error")
    func categoryForAuthError() {
        let error = AynaError.invalidAPIKey(provider: "Test")
        let category = ErrorPresenter.category(for: error)

        #expect(category == .authentication)
    }

    @Test("Category for tool error")
    func categoryForToolError() {
        let error = AynaError.toolNotFound(toolName: "test")
        let category = ErrorPresenter.category(for: error)

        #expect(category == .tool)
    }

    @Test("Timeout error is retryable")
    func isRetryableForTimeout() {
        let error = AynaError.timeout
        #expect(ErrorPresenter.isRetryable(error))
    }

    @Test("Missing API key error is not retryable")
    func isRetryableForMissingAPIKey() {
        let error = AynaError.missingAPIKey(provider: "Test")
        #expect(!ErrorPresenter.isRetryable(error))
    }

    @Test("Missing API key requires user action")
    func requiresUserActionForMissingAPIKey() {
        let error = AynaError.missingAPIKey(provider: "Test")
        #expect(ErrorPresenter.requiresUserAction(error))
    }

    @Test("Timeout does not require user action")
    func requiresUserActionForTimeout() {
        let error = AynaError.timeout
        #expect(!ErrorPresenter.requiresUserAction(error))
    }

    @Test("Suggested action for timeout is retry")
    func suggestedActionRetry() {
        let error = AynaError.timeout
        let action = ErrorPresenter.suggestedAction(for: error)

        #expect(action == .retry)
    }

    @Test("Suggested action for missing API key is open settings")
    func suggestedActionOpenSettings() {
        let error = AynaError.missingAPIKey(provider: "Test")
        let action = ErrorPresenter.suggestedAction(for: error)

        #expect(action == .openSettings)
    }

    @Test("Suggested action for cancelled is dismiss")
    func suggestedActionDismiss() {
        let error = AynaError.cancelled
        let action = ErrorPresenter.suggestedAction(for: error)

        #expect(action == .dismiss)
    }
}
