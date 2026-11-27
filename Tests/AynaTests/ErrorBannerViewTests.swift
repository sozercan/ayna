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
            openSettingsTab: .models,
            onDismiss: {},
            identifierPrefix: prefix
        )

        #expect(view.message == message)
        #expect(view.recoverySuggestion == suggestion)
        #expect(view.openSettingsTab == .models)
        #expect(view.identifierPrefix == prefix)
    }
}

@Suite("Error Recovery Suggestion Tests")
struct ErrorRecoverySuggestionTests {
    @Test("AynaError missingAPIKey has recovery suggestion")
    func aynaErrorMissingAPIKeyHasRecoverySuggestion() {
        let error = AynaError.missingAPIKey(provider: "OpenAI")

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    @Test("AynaError noModelSelected has recovery suggestion")
    func aynaErrorNoModelSelectedHasRecoverySuggestion() {
        let error = AynaError.noModelSelected

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Models") ?? false)
    }

    @Test("AynaError invalidResponse has recovery suggestion")
    func aynaErrorInvalidResponseHasRecoverySuggestion() {
        let error = AynaError.invalidResponse(detail: nil)

        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("again") ?? false)
    }

    @Test("AynaError contentFiltered has recovery suggestion")
    func aynaErrorContentFilteredHasRecoverySuggestion() {
        let error = AynaError.contentFiltered(reason: "test content")

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
            AynaError.missingAPIKey(provider: "OpenAI"),
            AynaError.noModelSelected,
            AynaError.invalidResponse(detail: nil),
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
            AynaError.missingAPIKey(provider: "OpenAI"),
            AynaError.noModelSelected,
            AynaError.invalidResponse(detail: nil),
            TavilyError.notConfigured,
            TavilyError.invalidAPIKey,
        ]

        for error in errors {
            #expect(error.recoverySuggestion != nil, "Error \(error) should have a recovery suggestion")
        }
    }
}
