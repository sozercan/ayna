@testable import Ayna
import SwiftUI
import Testing

@Suite("ErrorBannerView Tests")
@MainActor
struct ErrorBannerViewTests {
    @Test("Init with basic message")
    func initWithBasicMessage() {
        let message = "Test error message"

        let view = ErrorBannerView(
            message: message,
            onDismiss: {}
        )

        #expect(view != nil)
    }

    @Test("Init with recovery suggestion")
    func initWithRecoverySuggestion() {
        let message = "API Error"
        let suggestion = "Check your API key"

        let view = ErrorBannerView(
            message: message,
            recoverySuggestion: suggestion,
            onDismiss: {}
        )

        #expect(view != nil)
    }

    @Test("Init with retry action")
    func initWithRetryAction() {
        let message = "Network error"

        let view = ErrorBannerView(
            message: message,
            onRetry: {},
            onDismiss: {}
        )

        #expect(view != nil)
    }

    @Test("Init with all parameters")
    func initWithAllParameters() {
        let message = "Connection failed"
        let suggestion = "Check your internet connection"
        let prefix = "custom.error"

        let view = ErrorBannerView(
            message: message,
            recoverySuggestion: suggestion,
            onRetry: {},
            onDismiss: {},
            identifierPrefix: prefix
        )

        #expect(view != nil)
    }
}

@Suite("Error Recovery Suggestion Tests")
struct ErrorRecoverySuggestionTests {
    @Test("AIError missingAPIKey has recovery suggestion")
    func openAIErrorMissingAPIKeyHasRecoverySuggestion() {
        let error = AIService.AIError.missingAPIKey

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    @Test("AIError missingModel has recovery suggestion")
    func openAIErrorMissingModelHasRecoverySuggestion() {
        let error = AIService.AIError.missingModel

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Models") ?? false)
    }

    @Test("AIError invalidResponse has recovery suggestion")
    func openAIErrorInvalidResponseHasRecoverySuggestion() {
        let error = AIService.AIError.invalidResponse

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("again") ?? false)
    }

    @Test("AIError contentFiltered has recovery suggestion")
    func openAIErrorContentFilteredHasRecoverySuggestion() {
        let error = AIService.AIError.contentFiltered("test content")

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("rephras") ?? false)
    }

    @Test("TavilyError notConfigured has recovery suggestion")
    func tavilyErrorNotConfiguredHasRecoverySuggestion() {
        let error = TavilyError.notConfigured

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    @Test("TavilyError rateLimitExceeded has recovery suggestion")
    func tavilyErrorRateLimitHasRecoverySuggestion() {
        let error = TavilyError.rateLimitExceeded

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Wait") ?? false)
    }

    @Test("TavilyError invalidAPIKey has recovery suggestion")
    func tavilyErrorInvalidAPIKeyHasRecoverySuggestion() {
        let error = TavilyError.invalidAPIKey

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Check") ?? false)
    }
}

@Suite("LocalizedError Extension Tests")
struct LocalizedErrorExtensionTests {
    @Test("Error description is not nil")
    func errorDescriptionIsNotNil() {
        let errors: [any LocalizedError] = [
            AIService.AIError.missingAPIKey,
            AIService.AIError.missingModel,
            AIService.AIError.invalidResponse,
            TavilyError.notConfigured,
            TavilyError.invalidAPIKey,
        ]

        for error in errors {
            #expect(error.errorDescription != nil, "Error \(error) should have an error description")
        }
    }

    @Test("Recovery suggestion is not nil")
    func recoverySuggestionIsNotNil() {
        let errors: [any LocalizedError] = [
            AIService.AIError.missingAPIKey,
            AIService.AIError.missingModel,
            AIService.AIError.invalidResponse,
            TavilyError.notConfigured,
            TavilyError.invalidAPIKey,
        ]

        for error in errors {
            #expect(error.recoverySuggestion != nil, "Error \(error) should have a recovery suggestion")
        }
    }
}
