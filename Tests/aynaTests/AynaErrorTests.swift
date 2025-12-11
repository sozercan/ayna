//
//  AynaErrorTests.swift
//  aynaTests
//
//  Unit tests for AynaError and ErrorPresenter.
//

import Foundation
import XCTest

@testable import Ayna

final class AynaErrorTests: XCTestCase {
    // MARK: - Error Description Tests

    func testNetworkErrorDescription() {
        let urlError = URLError(.notConnectedToInternet)
        let error = AynaError.networkError(underlying: urlError)

        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Network error") == true)
    }

    func testTimeoutErrorDescription() {
        let error = AynaError.timeout

        XCTAssertEqual(error.errorDescription, "Request timed out")
        XCTAssertNotNil(error.recoverySuggestion)
    }

    func testMissingAPIKeyErrorDescription() {
        let error = AynaError.missingAPIKey(provider: "OpenAI")

        XCTAssertEqual(error.errorDescription, "OpenAI API key not configured")
        XCTAssertTrue(error.recoverySuggestion?.contains("Settings") == true)
    }

    func testInvalidAPIKeyErrorDescription() {
        let error = AynaError.invalidAPIKey(provider: "GitHub")

        XCTAssertEqual(error.errorDescription, "Invalid GitHub API key")
    }

    func testNoModelSelectedErrorDescription() {
        let error = AynaError.noModelSelected

        XCTAssertEqual(error.errorDescription, "No model selected")
        XCTAssertTrue(error.recoverySuggestion?.contains("Settings") == true)
    }

    func testModelNotFoundErrorDescription() {
        let error = AynaError.modelNotFound(modelName: "gpt-5")

        XCTAssertEqual(error.errorDescription, "Model 'gpt-5' not found")
    }

    func testContentFilteredErrorDescription() {
        let error = AynaError.contentFiltered(reason: "Inappropriate content")

        XCTAssertTrue(error.errorDescription?.contains("Content filtered") == true)
        XCTAssertEqual(error.recoverySuggestion, "Try rephrasing your message")
    }

    func testToolNotFoundErrorDescription() {
        let error = AynaError.toolNotFound(toolName: "web_search")

        XCTAssertEqual(error.errorDescription, "Tool 'web_search' not found")
    }

    func testToolExecutionFailedErrorDescription() {
        let error = AynaError.toolExecutionFailed(toolName: "calculator", reason: "Division by zero")

        XCTAssertTrue(error.errorDescription?.contains("calculator") == true)
        XCTAssertTrue(error.errorDescription?.contains("Division by zero") == true)
    }

    func testRateLimitedErrorDescription() {
        let error = AynaError.rateLimited(retryAfter: 60)

        XCTAssertTrue(error.errorDescription?.contains("Rate limit") == true)
        XCTAssertTrue(error.recoverySuggestion?.contains("60") == true)
    }

    func testCancelledErrorDescription() {
        let error = AynaError.cancelled

        XCTAssertEqual(error.errorDescription, "Operation was cancelled")
        XCTAssertNil(error.recoverySuggestion)
    }

    // MARK: - Error Wrapping Tests

    func testWrapURLErrorTimeout() {
        let urlError = URLError(.timedOut)
        let wrapped = AynaError.wrap(urlError)

        XCTAssertEqual(wrapped, .timeout)
    }

    func testWrapURLErrorNoConnection() {
        let urlError = URLError(.notConnectedToInternet)
        let wrapped = AynaError.wrap(urlError)

        if case .networkError = wrapped {
            // Pass
        } else {
            XCTFail("Expected networkError")
        }
    }

    func testWrapURLErrorCancelled() {
        let urlError = URLError(.cancelled)
        let wrapped = AynaError.wrap(urlError)

        XCTAssertEqual(wrapped, .cancelled)
    }

    func testWrapCancellationError() {
        let error = CancellationError()
        let wrapped = AynaError.wrap(error)

        XCTAssertEqual(wrapped, .cancelled)
    }

    func testWrapAynaErrorPassthrough() {
        let original = AynaError.timeout
        let wrapped = AynaError.wrap(original)

        XCTAssertEqual(wrapped, .timeout)
    }

    func testWrapUnknownError() {
        struct CustomError: Error {}
        let error = CustomError()
        let wrapped = AynaError.wrap(error)

        if case .unknown = wrapped {
            // Pass
        } else {
            XCTFail("Expected unknown error")
        }
    }

    // MARK: - HTTP Response Conversion Tests

    func testFromHTTPResponse401() {
        let error = AynaError.fromHTTPResponse(statusCode: 401, data: nil)

        if case let .invalidAPIKey(provider) = error {
            XCTAssertEqual(provider, "API")
        } else {
            XCTFail("Expected invalidAPIKey")
        }
    }

    func testFromHTTPResponse429() {
        let error = AynaError.fromHTTPResponse(statusCode: 429, data: nil)

        if case .rateLimited = error {
            // Pass
        } else {
            XCTFail("Expected rateLimited")
        }
    }

    func testFromHTTPResponse500WithJSONError() {
        let json = """
        {"error": {"message": "Internal server error"}}
        """.data(using: .utf8)

        let error = AynaError.fromHTTPResponse(statusCode: 500, data: json)

        if case let .httpError(statusCode, message) = error {
            XCTAssertEqual(statusCode, 500)
            XCTAssertEqual(message, "Internal server error")
        } else {
            XCTFail("Expected httpError")
        }
    }

    // MARK: - Equatable Tests

    func testEquatableSimpleCases() {
        XCTAssertEqual(AynaError.timeout, AynaError.timeout)
        XCTAssertEqual(AynaError.noModelSelected, AynaError.noModelSelected)
        XCTAssertEqual(AynaError.cancelled, AynaError.cancelled)
    }

    func testEquatableWithParameters() {
        XCTAssertEqual(
            AynaError.missingAPIKey(provider: "OpenAI"),
            AynaError.missingAPIKey(provider: "OpenAI")
        )
        XCTAssertNotEqual(
            AynaError.missingAPIKey(provider: "OpenAI"),
            AynaError.missingAPIKey(provider: "Azure")
        )
    }

    func testEquatableHTTPError() {
        XCTAssertEqual(
            AynaError.httpError(statusCode: 500, message: "Error"),
            AynaError.httpError(statusCode: 500, message: "Error")
        )
        XCTAssertNotEqual(
            AynaError.httpError(statusCode: 500, message: "Error"),
            AynaError.httpError(statusCode: 404, message: "Error")
        )
    }
}

// MARK: - ErrorPresenter Tests

final class ErrorPresenterTests: XCTestCase {
    func testUserMessageForAynaError() {
        let error = AynaError.timeout
        let message = ErrorPresenter.userMessage(for: error)

        XCTAssertEqual(message, "Request timed out")
    }

    func testUserMessageForURLError() {
        let error = URLError(.notConnectedToInternet)
        let message = ErrorPresenter.userMessage(for: error)

        XCTAssertEqual(message, "No internet connection")
    }

    func testRecoverySuggestionForAynaError() {
        let error = AynaError.missingAPIKey(provider: "OpenAI")
        let suggestion = ErrorPresenter.recoverySuggestion(for: error)

        XCTAssertNotNil(suggestion)
        XCTAssertTrue(suggestion?.contains("Settings") == true)
    }

    func testCategoryForNetworkError() {
        let error = AynaError.networkError(underlying: URLError(.timedOut))
        let category = ErrorPresenter.category(for: error)

        XCTAssertEqual(category, .network)
    }

    func testCategoryForAuthError() {
        let error = AynaError.invalidAPIKey(provider: "Test")
        let category = ErrorPresenter.category(for: error)

        XCTAssertEqual(category, .authentication)
    }

    func testCategoryForToolError() {
        let error = AynaError.toolNotFound(toolName: "test")
        let category = ErrorPresenter.category(for: error)

        XCTAssertEqual(category, .tool)
    }

    func testIsRetryableForTimeout() {
        let error = AynaError.timeout
        XCTAssertTrue(ErrorPresenter.isRetryable(error))
    }

    func testIsRetryableForMissingAPIKey() {
        let error = AynaError.missingAPIKey(provider: "Test")
        XCTAssertFalse(ErrorPresenter.isRetryable(error))
    }

    func testRequiresUserActionForMissingAPIKey() {
        let error = AynaError.missingAPIKey(provider: "Test")
        XCTAssertTrue(ErrorPresenter.requiresUserAction(error))
    }

    func testRequiresUserActionForTimeout() {
        let error = AynaError.timeout
        XCTAssertFalse(ErrorPresenter.requiresUserAction(error))
    }

    func testSuggestedActionRetry() {
        let error = AynaError.timeout
        let action = ErrorPresenter.suggestedAction(for: error)

        XCTAssertEqual(action, .retry)
    }

    func testSuggestedActionOpenSettings() {
        let error = AynaError.missingAPIKey(provider: "Test")
        let action = ErrorPresenter.suggestedAction(for: error)

        XCTAssertEqual(action, .openSettings)
    }

    func testSuggestedActionDismiss() {
        let error = AynaError.cancelled
        let action = ErrorPresenter.suggestedAction(for: error)

        XCTAssertEqual(action, .dismiss)
    }
}
