//
//  ErrorBannerViewTests.swift
//  aynaTests
//
//  Tests for ErrorBannerView component
//

@testable import Ayna
import SwiftUI
import Testing

@Suite("ErrorBannerView Tests")
@MainActor
struct ErrorBannerViewTests {
    // MARK: - Initialization Tests

    @Test("Init with basic message")
    func initWithBasicMessage() {
        // Given
        let message = "Test error message"

        // When
        let view = ErrorBannerView(
            message: message,
            onDismiss: {}
        )

        // Then - View should be created successfully
        #expect(view != nil)
    }

    @Test("Init with recovery suggestion")
    func initWithRecoverySuggestion() {
        // Given
        let message = "API Error"
        let suggestion = "Check your API key"

        // When
        let view = ErrorBannerView(
            message: message,
            recoverySuggestion: suggestion,
            onDismiss: {}
        )

        // Then - View should be created successfully
        #expect(view != nil)
    }

    @Test("Init with retry action")
    func initWithRetryAction() {
        // Given
        let message = "Network error"

        // When
        let view = ErrorBannerView(
            message: message,
            onRetry: {},
            onDismiss: {}
        )

        // Then - View should be created successfully
        #expect(view != nil)
    }

    @Test("Init with all parameters")
    func initWithAllParameters() {
        // Given
        let message = "Connection failed"
        let suggestion = "Check your internet connection"
        let prefix = "custom.error"

        // When
        let view = ErrorBannerView(
            message: message,
            recoverySuggestion: suggestion,
            onRetry: {},
            onDismiss: {},
            identifierPrefix: prefix
        )

        // Then - View should be created successfully
        #expect(view != nil)
    }
}

// MARK: - Error Enum Recovery Suggestion Tests

@Suite("Error Recovery Suggestion Tests")
struct ErrorRecoverySuggestionTests {
    // MARK: - AIError Tests

    @Test("AIError missingAPIKey has recovery suggestion")
    func openAIErrorMissingAPIKeyHasRecoverySuggestion() {
        // Given
        let error = AIService.AIError.missingAPIKey

        // Then
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    @Test("AIError missingModel has recovery suggestion")
    func openAIErrorMissingModelHasRecoverySuggestion() {
        // Given
        let error = AIService.AIError.missingModel

        // Then
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Models") ?? false)
    }

    @Test("AIError invalidResponse has recovery suggestion")
    func openAIErrorInvalidResponseHasRecoverySuggestion() {
        // Given
        let error = AIService.AIError.invalidResponse

        // Then
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("again") ?? false)
    }

    @Test("AIError contentFiltered has recovery suggestion")
    func openAIErrorContentFilteredHasRecoverySuggestion() {
        // Given
        let error = AIService.AIError.contentFiltered("test content")

        // Then
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("rephras") ?? false)
    }

    // MARK: - TavilyError Tests

    @Test("TavilyError notConfigured has recovery suggestion")
    func tavilyErrorNotConfiguredHasRecoverySuggestion() {
        // Given
        let error = TavilyError.notConfigured

        // Then
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    @Test("TavilyError rateLimitExceeded has recovery suggestion")
    func tavilyErrorRateLimitHasRecoverySuggestion() {
        // Given
        let error = TavilyError.rateLimitExceeded

        // Then
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Wait") ?? false)
    }

    @Test("TavilyError invalidAPIKey has recovery suggestion")
    func tavilyErrorInvalidAPIKeyHasRecoverySuggestion() {
        // Given
        let error = TavilyError.invalidAPIKey

        // Then
        #expect(error.recoverySuggestion != nil)
        #expect(error.recoverySuggestion?.contains("Check") ?? false)
    }
}

// MARK: - LocalizedError Extension Tests

@Suite("LocalizedError Extension Tests")
struct LocalizedErrorExtensionTests {
    @Test("Error description is not nil")
    func errorDescriptionIsNotNil() {
        // Given
        let errors: [any LocalizedError] = [
            AIService.AIError.missingAPIKey,
            AIService.AIError.missingModel,
            AIService.AIError.invalidResponse,
            TavilyError.notConfigured,
            TavilyError.invalidAPIKey,
        ]

        // Then
        for error in errors {
            #expect(error.errorDescription != nil, "Error \(error) should have an error description")
        }
    }

    @Test("Recovery suggestion is not nil")
    func recoverySuggestionIsNotNil() {
        // Given
        let errors: [any LocalizedError] = [
            AIService.AIError.missingAPIKey,
            AIService.AIError.missingModel,
            AIService.AIError.invalidResponse,
            TavilyError.notConfigured,
            TavilyError.invalidAPIKey,
        ]

        // Then
        for error in errors {
            #expect(error.recoverySuggestion != nil, "Error \(error) should have a recovery suggestion")
        }
    }
}
