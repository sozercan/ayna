//
//  AynaErrorTests.swift
//  aynaTests
//
//  Unit tests for AynaError and ErrorPresenter.
//

@testable import Ayna
import Foundation
import Testing

// MARK: - CustomTestStringConvertible Extension for Better Diagnostics

extension AynaError: @retroactive CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case .timeout: "AynaError.timeout"
        case .cancelled: "AynaError.cancelled"
        case .noModelSelected: "AynaError.noModelSelected"
        case let .missingAPIKey(provider): "AynaError.missingAPIKey(\(provider))"
        case let .invalidAPIKey(provider): "AynaError.invalidAPIKey(\(provider))"
        case let .modelNotFound(name): "AynaError.modelNotFound(\(name))"
        case let .httpError(code, msg): "AynaError.httpError(\(code), \"\(msg.prefix(20))...\")"
        case let .rateLimited(retry): "AynaError.rateLimited(retryAfter: \(retry ?? 0))"
        case let .toolNotFound(name): "AynaError.toolNotFound(\(name))"
        case let .toolExecutionFailed(name, _): "AynaError.toolExecutionFailed(\(name))"
        case .networkError: "AynaError.networkError"
        case .contentFiltered: "AynaError.contentFiltered"
        case .unknown: "AynaError.unknown"
        }
    }
}

// MARK: - Test Input Types for Parameterized Tests

/// Test case for error description validation
private struct ErrorDescriptionCase: Sendable {
    let error: AynaError
    let expectedContains: String
    let hasRecoverySuggestion: Bool

    var label: String {
        expectedContains
    }
}

/// Test case for URLError wrapping
private struct URLErrorWrapCase: Sendable, CustomTestStringConvertible {
    let code: URLError.Code
    let expectedCase: ExpectedAynaError

    var testDescription: String {
        "URLError.\(code) → \(expectedCase)"
    }

    enum ExpectedAynaError: Sendable, CustomStringConvertible {
        case timeout
        case cancelled
        case networkError

        var description: String {
            switch self {
            case .timeout: "timeout"
            case .cancelled: "cancelled"
            case .networkError: "networkError"
            }
        }

        func matches(_ error: AynaError) -> Bool {
            switch self {
            case .timeout: error == .timeout
            case .cancelled: error == .cancelled
            case .networkError:
                if case .networkError = error { return true }
                return false
            }
        }
    }
}

@Suite("AynaError Tests", .tags(.errorHandling, .fast))
struct AynaErrorTests {
    // MARK: - Error Description Tests (Parameterized)

    @Test("Error descriptions are correct", arguments: [
        ErrorDescriptionCase(error: .timeout, expectedContains: "Request timed out", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .noModelSelected, expectedContains: "No model selected", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .cancelled, expectedContains: "Operation was cancelled", hasRecoverySuggestion: false),
        ErrorDescriptionCase(error: .missingAPIKey(provider: "OpenAI"), expectedContains: "OpenAI API key not configured", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .invalidAPIKey(provider: "GitHub"), expectedContains: "Invalid GitHub API key", hasRecoverySuggestion: false),
        ErrorDescriptionCase(error: .modelNotFound(modelName: "gpt-5"), expectedContains: "Model 'gpt-5' not found", hasRecoverySuggestion: false),
        ErrorDescriptionCase(error: .toolNotFound(toolName: "web_search"), expectedContains: "Tool 'web_search' not found", hasRecoverySuggestion: false),
        ErrorDescriptionCase(error: .rateLimited(retryAfter: 60), expectedContains: "Rate limit", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .contentFiltered(reason: "Inappropriate"), expectedContains: "Content filtered", hasRecoverySuggestion: true)
    ])
    func errorDescriptions(testCase: ErrorDescriptionCase) {
        #expect(testCase.error.errorDescription?.contains(testCase.expectedContains) == true)
        #expect((testCase.error.recoverySuggestion != nil) == testCase.hasRecoverySuggestion)
    }

    @Test("Network error has correct description")
    func networkErrorDescription() {
        let urlError = URLError(.notConnectedToInternet)
        let error = AynaError.networkError(underlying: urlError)

        #expect(error.errorDescription != nil)
        #expect(error.errorDescription?.contains("Network error") == true)
    }

    @Test("Tool execution failed error has correct description")
    func toolExecutionFailedErrorDescription() {
        let error = AynaError.toolExecutionFailed(toolName: "calculator", reason: "Division by zero")

        #expect(error.errorDescription?.contains("calculator") == true)
        #expect(error.errorDescription?.contains("Division by zero") == true)
    }

    // MARK: - Error Wrapping Tests (Parameterized)

    @Test("URLError wrapping returns correct AynaError", arguments: [
        URLErrorWrapCase(code: .timedOut, expectedCase: .timeout),
        URLErrorWrapCase(code: .cancelled, expectedCase: .cancelled),
        URLErrorWrapCase(code: .notConnectedToInternet, expectedCase: .networkError),
        URLErrorWrapCase(code: .networkConnectionLost, expectedCase: .networkError)
    ])
    func wrapURLError(testCase: URLErrorWrapCase) {
        let urlError = URLError(testCase.code)
        let wrapped = AynaError.wrap(urlError)
        #expect(testCase.expectedCase.matches(wrapped))
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

        guard case .unknown = wrapped else {
            Issue.record("Expected unknown error, got \(wrapped)")
            return
        }
    }

    // MARK: - HTTP Response Conversion Tests

    @Test("HTTP response 401 returns invalid API key error")
    func fromHTTPResponse401() {
        let error = AynaError.fromHTTPResponse(statusCode: 401, data: nil)

        guard case let .invalidAPIKey(provider) = error else {
            Issue.record("Expected invalidAPIKey, got \(error)")
            return
        }
        #expect(provider == "API")
    }

    @Test("HTTP response 429 returns rate limited error")
    func fromHTTPResponse429() {
        let error = AynaError.fromHTTPResponse(statusCode: 429, data: nil)

        guard case .rateLimited = error else {
            Issue.record("Expected rateLimited, got \(error)")
            return
        }
    }

    @Test("HTTP response 500 with JSON error parses message")
    func fromHTTPResponse500WithJSONError() {
        let json = Data("""
        {"error": {"message": "Internal server error"}}
        """.utf8)

        let error = AynaError.fromHTTPResponse(statusCode: 500, data: json)

        guard case let .httpError(statusCode, message) = error else {
            Issue.record("Expected httpError, got \(error)")
            return
        }
        #expect(statusCode == 500)
        #expect(message == "Internal server error")
    }

    // MARK: - Equatable Tests (Parameterized)

    @Test("Simple error cases are equatable", arguments: [
        AynaError.timeout,
        AynaError.noModelSelected,
        AynaError.cancelled
    ])
    func equatableSimpleCases(error: AynaError) {
        #expect(error == error)
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

/// Test case for suggested actions
private struct SuggestedActionCase: Sendable, CustomTestStringConvertible {
    let error: AynaError
    let expectedAction: ErrorPresenter.SuggestedAction

    var testDescription: String {
        "\(error) → \(expectedAction)"
    }
}

@Suite("ErrorPresenter Tests", .tags(.errorHandling, .fast))
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

    // MARK: - Category Tests (Parameterized)

    @Test("Error category is correct", arguments: zip(
        [
            AynaError.networkError(underlying: URLError(.timedOut)),
            AynaError.invalidAPIKey(provider: "Test"),
            AynaError.toolNotFound(toolName: "test")
        ] as [AynaError],
        [
            ErrorPresenter.ErrorCategory.network,
            ErrorPresenter.ErrorCategory.authentication,
            ErrorPresenter.ErrorCategory.tool
        ]
    ))
    func errorCategory(error: AynaError, expectedCategory: ErrorPresenter.ErrorCategory) {
        let category = ErrorPresenter.category(for: error)
        #expect(category == expectedCategory)
    }

    // MARK: - Retryable Tests (Parameterized)

    @Test("Retryable errors are identified correctly", arguments: zip(
        [AynaError.timeout, AynaError.missingAPIKey(provider: "Test")],
        [true, false]
    ))
    func isRetryable(error: AynaError, expected: Bool) {
        #expect(ErrorPresenter.isRetryable(error) == expected)
    }

    // MARK: - Requires User Action Tests (Parameterized)

    @Test("User action requirement is correct", arguments: zip(
        [AynaError.missingAPIKey(provider: "Test"), AynaError.timeout],
        [true, false]
    ))
    func requiresUserAction(error: AynaError, expected: Bool) {
        #expect(ErrorPresenter.requiresUserAction(error) == expected)
    }

    // MARK: - Suggested Action Tests (Parameterized)

    @Test("Suggested action is correct", arguments: [
        SuggestedActionCase(error: .timeout, expectedAction: .retry),
        SuggestedActionCase(error: .missingAPIKey(provider: "Test"), expectedAction: .openSettings),
        SuggestedActionCase(error: .cancelled, expectedAction: .dismiss)
    ])
    func suggestedAction(testCase: SuggestedActionCase) {
        let action = ErrorPresenter.suggestedAction(for: testCase.error)
        #expect(action == testCase.expectedAction)
    }
}
