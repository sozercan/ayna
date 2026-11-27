@testable import Ayna
import Foundation
import Testing

extension AynaError: CustomTestStringConvertible {
    public var testDescription: String {
        switch self {
        case .timeout: "AynaError.timeout"
        case .cancelled: "AynaError.cancelled"
        case .noModelSelected: "AynaError.noModelSelected"
        case let .missingAPIKey(provider): "AynaError.missingAPIKey(\(provider))"
        case let .invalidAPIKey(provider): "AynaError.invalidAPIKey(\(provider))"
        case let .modelNotFound(name): "AynaError.modelNotFound(\(name))"
        case let .httpError(code, msg): "AynaError.httpError(\(code), \"\((msg ?? "").prefix(20))...\")"
        case let .rateLimited(retry): "AynaError.rateLimited(retryAfter: \(retry ?? 0))"
        case let .toolNotFound(name): "AynaError.toolNotFound(\(name))"
        case let .toolExecutionFailed(name, _): "AynaError.toolExecutionFailed(\(name))"
        case .networkError: "AynaError.networkError"
        case .contentFiltered: "AynaError.contentFiltered"
        case .unknown: "AynaError.unknown"
        case let .missingConfiguration(detail): "AynaError.missingConfiguration(\(detail))"
        case let .authenticationFailed(reason): "AynaError.authenticationFailed(\(reason))"
        case let .invalidEndpoint(url): "AynaError.invalidEndpoint(\(url))"
        case let .unsupportedProvider(provider, op): "AynaError.unsupportedProvider(\(provider), \(op))"
        case let .capabilityMismatch(expected, actual): "AynaError.capabilityMismatch(\(expected), \(actual))"
        case let .invalidResponse(detail): "AynaError.invalidResponse(\(detail ?? "nil"))"
        case let .apiError(message): "AynaError.apiError(\(message))"
        case let .toolChainDepthExceeded(maxDepth): "AynaError.toolChainDepthExceeded(\(maxDepth))"
        case let .encodingFailed(detail): "AynaError.encodingFailed(\(detail))"
        case let .decodingFailed(detail): "AynaError.decodingFailed(\(detail))"
        case let .fileOperationFailed(op, path): "AynaError.fileOperationFailed(\(op), \(path ?? "nil"))"
        case let .keychainError(op, status): "AynaError.keychainError(\(op), \(status ?? 0))"
        case let .conversationNotFound(id): "AynaError.conversationNotFound(\(id))"
        case let .messageNotFound(id): "AynaError.messageNotFound(\(id))"
        }
    }
}

struct ErrorDescriptionCase: Sendable {
    let error: AynaError
    let expectedContains: String
    let hasRecoverySuggestion: Bool

    var label: String {
        expectedContains
    }
}

struct URLErrorWrapCase: Sendable, CustomTestStringConvertible {
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
            case .timeout: return error == .timeout
            case .cancelled: return error == .cancelled
            case .networkError:
                if case .networkError = error { return true }
                return false
            }
        }
    }
}

@Suite("AynaError Tests", .tags(.errorHandling, .fast))
struct AynaErrorTests {
    @Test("Error descriptions are correct", arguments: [
        ErrorDescriptionCase(error: .timeout, expectedContains: "Request timed out", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .noModelSelected, expectedContains: "No model selected", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .cancelled, expectedContains: "Operation was cancelled", hasRecoverySuggestion: false),
        ErrorDescriptionCase(error: .missingAPIKey(provider: "OpenAI"), expectedContains: "OpenAI API key not configured", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .modelNotFound(modelName: "gpt-5"), expectedContains: "Model 'gpt-5' not found", hasRecoverySuggestion: true),
        ErrorDescriptionCase(error: .toolNotFound(toolName: "web_search"), expectedContains: "Tool 'web_search' not found", hasRecoverySuggestion: true),
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

struct SuggestedActionCase: Sendable, CustomTestStringConvertible {
    let error: AynaError
    let expectedAction: ErrorPresenter.ErrorAction

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
        let error = AynaError.apiError(message: leakingMessage)

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

    @Test("Error category is correct for AynaError cases", arguments: zip(
        [
            AynaError.networkError(underlying: URLError(.timedOut)),
            AynaError.timeout,
            AynaError.missingAPIKey(provider: "OpenAI"),
            AynaError.invalidAPIKey(provider: "Test"),
            AynaError.authenticationFailed(reason: "expired token"),
            AynaError.missingConfiguration(detail: "endpoint"),
            AynaError.invalidEndpoint("ftp://example.com"),
            AynaError.noModelSelected,
            AynaError.modelNotFound(modelName: "gpt-5"),
            AynaError.unsupportedProvider(provider: "Test", operation: "images"),
            AynaError.capabilityMismatch(expected: "vision", actual: "text"),
            AynaError.httpError(statusCode: 500, message: "Internal failure"),
            AynaError.rateLimited(retryAfter: 30),
            AynaError.invalidResponse(detail: "empty body"),
            AynaError.contentFiltered(reason: "policy"),
            AynaError.apiError(message: "Custom backend failure"),
            AynaError.toolNotFound(toolName: "test"),
            AynaError.toolExecutionFailed(toolName: "bash", reason: "exit 1"),
            AynaError.toolChainDepthExceeded(maxDepth: 5),
            AynaError.encodingFailed(detail: "bad utf8"),
            AynaError.decodingFailed(detail: "missing field"),
            AynaError.fileOperationFailed(operation: "read", path: "/tmp/x"),
            AynaError.keychainError(operation: "load", status: -25300),
            AynaError.conversationNotFound(id: UUID()),
            AynaError.messageNotFound(id: UUID()),
            AynaError.cancelled,
            AynaError.unknown(message: "Unexpected failure", underlying: nil)
        ] as [AynaError],
        [
            ErrorPresenter.ErrorCategory.network,
            ErrorPresenter.ErrorCategory.network,
            ErrorPresenter.ErrorCategory.authentication,
            ErrorPresenter.ErrorCategory.authentication,
            ErrorPresenter.ErrorCategory.authentication,
            ErrorPresenter.ErrorCategory.configuration,
            ErrorPresenter.ErrorCategory.configuration,
            ErrorPresenter.ErrorCategory.configuration,
            ErrorPresenter.ErrorCategory.configuration,
            ErrorPresenter.ErrorCategory.configuration,
            ErrorPresenter.ErrorCategory.configuration,
            ErrorPresenter.ErrorCategory.api,
            ErrorPresenter.ErrorCategory.api,
            ErrorPresenter.ErrorCategory.api,
            ErrorPresenter.ErrorCategory.api,
            ErrorPresenter.ErrorCategory.api,
            ErrorPresenter.ErrorCategory.tool,
            ErrorPresenter.ErrorCategory.tool,
            ErrorPresenter.ErrorCategory.tool,
            ErrorPresenter.ErrorCategory.data,
            ErrorPresenter.ErrorCategory.data,
            ErrorPresenter.ErrorCategory.data,
            ErrorPresenter.ErrorCategory.data,
            ErrorPresenter.ErrorCategory.conversation,
            ErrorPresenter.ErrorCategory.conversation,
            ErrorPresenter.ErrorCategory.cancelled,
            ErrorPresenter.ErrorCategory.unknown
        ]
    ))
    func errorCategory(error: AynaError, expectedCategory: ErrorPresenter.ErrorCategory) {
        let category = ErrorPresenter.category(for: error)
        #expect(category == expectedCategory)
    }

    @Test("Error category uses AynaError case rather than message text heuristics")
    func errorCategoryIgnoresMisleadingMessageText() {
        let apiError = AynaError.apiError(message: "Invalid api key for tool 'search' timed out")
        let unknownError = AynaError.unknown(message: "No model selected: keychain failed", underlying: nil)

        #expect(ErrorPresenter.category(for: apiError) == .api)
        #expect(ErrorPresenter.category(for: unknownError) == .unknown)
        #expect(!ErrorPresenter.isRetryable(apiError))
        #expect(!ErrorPresenter.requiresUserAction(unknownError))
    }

    @Test("Error category handles non-AynaError fallbacks")
    func errorCategoryFallbacks() {
        struct GenericError: LocalizedError {
            var errorDescription: String? {
                "API key timed out"
            }
        }

        #expect(ErrorPresenter.category(for: CancellationError()) == .cancelled)
        #expect(ErrorPresenter.category(for: URLError(.cancelled)) == .cancelled)
        #expect(ErrorPresenter.category(for: URLError(.notConnectedToInternet)) == .network)
        #expect(ErrorPresenter.category(for: HTTPStatusError(statusCode: 401, message: "Unauthorized")) == .authentication)
        #expect(ErrorPresenter.category(for: HTTPStatusError(statusCode: 403, message: "Forbidden")) == .authentication)
        #expect(ErrorPresenter.category(for: HTTPStatusError(statusCode: 429, message: "Rate limit")) == .api)
        #expect(ErrorPresenter.category(for: HTTPStatusError(statusCode: 503, message: "Unavailable")) == .api)
        #expect(ErrorPresenter.category(for: GenericError()) == .unknown)
    }

    @Test("HTTPStatusError retryability and user action requirements")
    func httpStatusErrorClassification() {
        let unauthorized = HTTPStatusError(statusCode: 401, message: "Unauthorized")
        let forbidden = HTTPStatusError(statusCode: 403, message: "Forbidden")
        let badRequest = HTTPStatusError(statusCode: 400, message: "Bad request")
        let rateLimited = HTTPStatusError(statusCode: 429, message: "Too many requests")
        let serverError = HTTPStatusError(statusCode: 503, message: "Service unavailable")

        #expect(!ErrorPresenter.isRetryable(unauthorized))
        #expect(ErrorPresenter.requiresUserAction(unauthorized))
        #expect(ErrorPresenter.suggestedAction(for: unauthorized) == .openSettings)

        #expect(!ErrorPresenter.isRetryable(forbidden))
        #expect(ErrorPresenter.requiresUserAction(forbidden))
        #expect(ErrorPresenter.suggestedAction(for: forbidden) == .openSettings)

        #expect(!ErrorPresenter.isRetryable(badRequest))
        #expect(!ErrorPresenter.requiresUserAction(badRequest))
        #expect(ErrorPresenter.suggestedAction(for: badRequest) == .dismiss)

        #expect(ErrorPresenter.isRetryable(rateLimited))
        #expect(!ErrorPresenter.requiresUserAction(rateLimited))
        #expect(ErrorPresenter.suggestedAction(for: rateLimited) == .retry)

        #expect(ErrorPresenter.isRetryable(serverError))
        #expect(!ErrorPresenter.requiresUserAction(serverError))
        #expect(ErrorPresenter.suggestedAction(for: serverError) == .retry)
    }

    @Test("Retryable errors are identified correctly", arguments: zip(
        [
            AynaError.timeout,
            AynaError.networkError(underlying: URLError(.notConnectedToInternet)),
            AynaError.rateLimited(retryAfter: 10),
            AynaError.httpError(statusCode: 503, message: nil),
            AynaError.httpError(statusCode: 400, message: "Bad request"),
            AynaError.missingAPIKey(provider: "Test"),
            AynaError.cancelled
        ] as [AynaError],
        [true, true, true, true, false, false, false]
    ))
    func isRetryable(error: AynaError, expected: Bool) {
        #expect(ErrorPresenter.isRetryable(error) == expected)
    }

    @Test("Retryable fallback for URLError")
    func isRetryableURLError() {
        #expect(ErrorPresenter.isRetryable(URLError(.timedOut)))
        #expect(ErrorPresenter.isRetryable(URLError(.networkConnectionLost)))
        #expect(!ErrorPresenter.isRetryable(URLError(.badURL)))
    }

    @Test("User action requirement is correct", arguments: zip(
        [
            AynaError.missingAPIKey(provider: "Test"),
            AynaError.invalidAPIKey(provider: "Test"),
            AynaError.authenticationFailed(reason: "expired"),
            AynaError.missingConfiguration(detail: "url"),
            AynaError.invalidEndpoint("bad"),
            AynaError.noModelSelected,
            AynaError.modelNotFound(modelName: "gpt-5"),
            AynaError.unsupportedProvider(provider: "Test", operation: "images"),
            AynaError.capabilityMismatch(expected: "vision", actual: "text"),
            AynaError.timeout,
            AynaError.rateLimited(retryAfter: 5),
            AynaError.cancelled
        ] as [AynaError],
        [true, true, true, true, true, true, true, true, true, false, false, false]
    ))
    func requiresUserAction(error: AynaError, expected: Bool) {
        #expect(ErrorPresenter.requiresUserAction(error) == expected)
    }

    @Test("Suggested action is correct", arguments: [
        SuggestedActionCase(error: .timeout, expectedAction: .retry),
        SuggestedActionCase(error: .rateLimited(retryAfter: 10), expectedAction: .retry),
        SuggestedActionCase(error: .httpError(statusCode: 502, message: nil), expectedAction: .retry),
        SuggestedActionCase(error: .missingAPIKey(provider: "Test"), expectedAction: .openSettings),
        SuggestedActionCase(error: .invalidEndpoint("bad"), expectedAction: .openSettings),
        SuggestedActionCase(error: .cancelled, expectedAction: .dismiss),
        SuggestedActionCase(error: .apiError(message: "Unexpected"), expectedAction: .dismiss)
    ])
    func suggestedAction(testCase: SuggestedActionCase) {
        let action = ErrorPresenter.suggestedAction(for: testCase.error)
        #expect(action == testCase.expectedAction)
    }
}
