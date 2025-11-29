//
//  OpenAIRetryPolicy.swift
//  ayna
//
//  Created on 11/24/25.
//

import Foundation

/// Stateless helper that determines retry behavior for API requests.
/// Implements exponential backoff with jitter for transient failures.
enum OpenAIRetryPolicy {
    // MARK: - Configuration

    struct Config {
        let maxRetries: Int
        let initialDelay: TimeInterval
        let maxDelay: TimeInterval

        static let `default` = Config(
            maxRetries: 3,
            initialDelay: 1.0,
            maxDelay: 8.0
        )
    }

    // MARK: - Public API

    /// Determines if a request should be retried based on the error and attempt count.
    /// - Parameters:
    ///   - error: The error that occurred
    ///   - attempt: The current attempt number (0-based)
    ///   - hasReceivedData: Whether any data was received before the error
    ///   - config: Retry configuration (defaults to standard settings)
    /// - Returns: `true` if the request should be retried
    static func shouldRetry(
        error: Error,
        attempt: Int,
        hasReceivedData: Bool = false,
        config: Config = .default
    ) -> Bool {
        // Don't retry if we've exceeded max attempts
        guard attempt < config.maxRetries else { return false }

        // Don't retry if we already received data (partial response)
        guard !hasReceivedData else { return false }

        // Don't retry cancellations
        if isCancellationError(error) { return false }

        // Check for retryable URL errors
        if let urlError = error as? URLError {
            return isRetryableURLError(urlError)
        }

        // Check for retryable API errors
        if let openAIError = error as? OpenAIService.OpenAIError {
            return isRetryableAPIError(openAIError)
        }

        return false
    }

    /// Calculates the delay before the next retry attempt.
    /// Uses exponential backoff with jitter to avoid thundering herd.
    /// If a retry-after date is provided (from rate limit headers), uses that instead.
    /// - Parameters:
    ///   - attempt: The current attempt number (0-based)
    ///   - retryAfterDate: Optional date from retry-after header
    ///   - config: Retry configuration
    /// - Returns: The delay in seconds
    static func delay(
        for attempt: Int,
        retryAfterDate: Date? = nil,
        config: Config = .default
    ) -> TimeInterval {
        // If we have a retry-after date, use that (capped at 60s to avoid very long waits)
        if let retryAfter = retryAfterDate {
            let retryDelay = max(0, retryAfter.timeIntervalSinceNow)
            return min(retryDelay, 60.0)
        }
        
        // Fall back to exponential backoff with jitter
        let exponentialDelay = config.initialDelay * pow(2.0, Double(attempt))
        let cappedDelay = min(exponentialDelay, config.maxDelay)
        let jitter = Double.random(in: 0 ... 0.1)
        return cappedDelay + jitter
    }

    /// Async helper that waits for the appropriate retry delay.
    /// - Parameters:
    ///   - attempt: The current attempt number (0-based)
    ///   - retryAfterDate: Optional date from retry-after header
    ///   - config: Retry configuration
    static func wait(
        for attempt: Int,
        retryAfterDate: Date? = nil,
        config: Config = .default
    ) async {
        let delaySeconds = delay(for: attempt, retryAfterDate: retryAfterDate, config: config)
        try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
    }

    // MARK: - Error Classification

    private static func isCancellationError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        if (error as NSError).code == NSURLErrorCancelled {
            return true
        }
        return false
    }

    private static func isRetryableURLError(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed:
            true
        default:
            false
        }
    }

    private static func isRetryableAPIError(_ error: OpenAIService.OpenAIError) -> Bool {
        switch error {
        case let .apiError(message):
            // Retry on rate limits and server errors
            let retryableStatusCodes = ["429", "500", "502", "503", "504"]
            return retryableStatusCodes.contains { message.contains($0) }
        default:
            return false
        }
    }
}
