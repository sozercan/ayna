//
//  ErrorBannerViewTests.swift
//  aynaTests
//
//  Tests for ErrorBannerView component
//

import SwiftUI
@testable import Ayna
import XCTest

final class ErrorBannerViewTests: XCTestCase {
    // MARK: - Initialization Tests

    func testInitWithBasicMessage() {
        // Given
        let message = "Test error message"

        // When
        let view = ErrorBannerView(
            message: message,
            onDismiss: {}
        )

        // Then - View should be created successfully
        XCTAssertNotNil(view)
    }

    func testInitWithRecoverySuggestion() {
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
        XCTAssertNotNil(view)
    }

    func testInitWithRetryAction() {
        // Given
        let message = "Network error"

        // When
        let view = ErrorBannerView(
            message: message,
            onRetry: {},
            onDismiss: {}
        )

        // Then - View should be created successfully
        XCTAssertNotNil(view)
    }

    func testInitWithAllParameters() {
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
        XCTAssertNotNil(view)
    }
}

// MARK: - Error Enum Recovery Suggestion Tests

final class ErrorRecoverySuggestionTests: XCTestCase {
    // MARK: - OpenAIError Tests

    func testOpenAIErrorMissingAPIKeyHasRecoverySuggestion() {
        // Given
        let error = OpenAIService.OpenAIError.missingAPIKey

        // Then
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    func testOpenAIErrorMissingModelHasRecoverySuggestion() {
        // Given
        let error = OpenAIService.OpenAIError.missingModel

        // Then
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("Models") ?? false)
    }

    func testOpenAIErrorInvalidResponseHasRecoverySuggestion() {
        // Given
        let error = OpenAIService.OpenAIError.invalidResponse

        // Then
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("again") ?? false)
    }

    func testOpenAIErrorContentFilteredHasRecoverySuggestion() {
        // Given
        let error = OpenAIService.OpenAIError.contentFiltered("test content")

        // Then
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("rephras") ?? false)
    }

    // MARK: - TavilyError Tests

    func testTavilyErrorNotConfiguredHasRecoverySuggestion() {
        // Given
        let error = TavilyError.notConfigured

        // Then
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("Settings") ?? false)
    }

    func testTavilyErrorRateLimitHasRecoverySuggestion() {
        // Given
        let error = TavilyError.rateLimitExceeded

        // Then
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("Wait") ?? false)
    }

    func testTavilyErrorInvalidAPIKeyHasRecoverySuggestion() {
        // Given
        let error = TavilyError.invalidAPIKey

        // Then
        XCTAssertNotNil(error.recoverySuggestion)
        XCTAssertTrue(error.recoverySuggestion?.contains("Check") ?? false)
    }

    // MARK: - AIKitError Tests (macOS only)

    #if os(macOS)
        func testAIKitErrorNoModelSelectedHasRecoverySuggestion() {
            // Given
            let error = AIKitError.noModelSelected

            // Then
            XCTAssertNotNil(error.recoverySuggestion)
            XCTAssertTrue(error.recoverySuggestion?.contains("Settings") ?? false)
        }

        func testAIKitErrorPodmanNotAvailableHasRecoverySuggestion() {
            // Given
            let error = AIKitError.podmanNotAvailable

            // Then
            XCTAssertNotNil(error.recoverySuggestion)
            XCTAssertTrue(error.recoverySuggestion?.contains("brew") ?? false)
        }
    #endif
}

// MARK: - LocalizedError Extension Tests

final class LocalizedErrorExtensionTests: XCTestCase {
    func testErrorDescriptionIsNotNil() {
        // Given
        let errors: [any LocalizedError] = [
            OpenAIService.OpenAIError.missingAPIKey,
            OpenAIService.OpenAIError.missingModel,
            OpenAIService.OpenAIError.invalidResponse,
            TavilyError.notConfigured,
            TavilyError.invalidAPIKey,
        ]

        // Then
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have an error description")
        }
    }

    func testRecoverySuggestionIsNotNil() {
        // Given
        let errors: [any LocalizedError] = [
            OpenAIService.OpenAIError.missingAPIKey,
            OpenAIService.OpenAIError.missingModel,
            OpenAIService.OpenAIError.invalidResponse,
            TavilyError.notConfigured,
            TavilyError.invalidAPIKey,
        ]

        // Then
        for error in errors {
            XCTAssertNotNil(error.recoverySuggestion, "Error \(error) should have a recovery suggestion")
        }
    }
}
