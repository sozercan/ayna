//
//  OpenAIRetryPolicy.swift
//  ayna
//
//  Created on 11/24/25.
//

import Foundation

#if canImport(os)
import os
#endif

// MARK: - Circuit Breaker

/// Thread-safe circuit breaker that prevents hammering failing endpoints.
/// States: Closed (normal) → Open (failing fast) → Half-Open (testing recovery)
final class CircuitBreaker: @unchecked Sendable {
    enum State: Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }

        struct Config: Sendable {
            /// Number of consecutive failures before opening the circuit
            let failureThreshold: Int
            /// How long the circuit stays open before allowing a test request
            let openDuration: TimeInterval
            /// Number of successes needed in half-open state to close
            let successThreshold: Int

            nonisolated static let `default` = Config(
                failureThreshold: 3,
                openDuration: 30.0,
                successThreshold: 2
            )
        }

        private let lock = NSLock()
        private var _state: State = .closed
        private var consecutiveFailures = 0
        private var consecutiveSuccesses = 0
        private let config: Config

        init(config: Config = .default) {
            self.config = config
        }

        /// Current state of the circuit breaker
        var state: State {
            lock.lock()
            defer { lock.unlock() }

            // Auto-transition from open to half-open if timeout expired
            if case let .open(until) = _state, Date() >= until {
                _state = .halfOpen
                consecutiveSuccesses = 0
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .info,
                    message: "⚡ Circuit breaker transitioning to half-open"
                )
            }
            return _state
        }

        /// Check if requests should be allowed through
        var shouldAllowRequest: Bool {
            switch state {
            case .closed, .halfOpen:
                true
            case .open:
                false
            }
        }

        /// Record a successful request
        func recordSuccess() {
            lock.lock()
            defer { lock.unlock() }

            consecutiveFailures = 0

            switch _state {
            case .halfOpen:
                consecutiveSuccesses += 1
                if consecutiveSuccesses >= config.successThreshold {
                    _state = .closed
                    consecutiveSuccesses = 0
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .info,
                        message: "✅ Circuit breaker closed after recovery"
                    )
                }
            case .closed, .open:
                break
            }
        }

        /// Record a failed request
        func recordFailure() {
            lock.lock()
            defer { lock.unlock() }

            consecutiveFailures += 1
            consecutiveSuccesses = 0

            switch _state {
            case .closed:
                if consecutiveFailures >= config.failureThreshold {
                    let openUntil = Date().addingTimeInterval(config.openDuration)
                    _state = .open(until: openUntil)
                    DiagnosticsLogger.log(
                        .openAIService,
                        level: .error,
                        message: "🔴 Circuit breaker opened after \(consecutiveFailures) failures",
                        metadata: ["reopensAt": openUntil.description]
                    )
                }
            case .halfOpen:
                // Failed during test - reopen the circuit
                let openUntil = Date().addingTimeInterval(config.openDuration)
                _state = .open(until: openUntil)
                DiagnosticsLogger.log(
                    .openAIService,
                    level: .error,
                    message: "🔴 Circuit breaker reopened after half-open failure"
                )
            case .open:
                break
            }
        }

        /// Reset the circuit breaker to closed state (for testing or manual override)
        func reset() {
            lock.lock()
            defer { lock.unlock() }
            _state = .closed
            consecutiveFailures = 0
            consecutiveSuccesses = 0
        }

        /// Time remaining until circuit transitions from open to half-open
        var timeUntilHalfOpen: TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            if case let .open(until) = _state {
                return max(0, until.timeIntervalSinceNow)
            }
            return nil
        }
    }

// MARK: - Circuit Breaker Registry

/// Manages circuit breakers per endpoint/provider to isolate failures
final class CircuitBreakerRegistry: @unchecked Sendable {
    static let shared = CircuitBreakerRegistry()

    private let lock = NSLock()
    private var breakers: [String: CircuitBreaker] = [:]
    private let defaultConfig: CircuitBreaker.Config

    init(config: CircuitBreaker.Config = .default) {
        defaultConfig = config
    }

    /// Get or create a circuit breaker for a specific endpoint
    func breaker(for endpoint: String) -> CircuitBreaker {
        lock.lock()
        defer { lock.unlock() }

        if let existing = breakers[endpoint] {
            return existing
        }

        let newBreaker = CircuitBreaker(config: defaultConfig)
        breakers[endpoint] = newBreaker
        return newBreaker
    }

    /// Reset all circuit breakers (for testing)
    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        breakers.values.forEach { $0.reset() }
        breakers.removeAll()
    }
}

// MARK: - Circuit Breaker Convenience

/// Thin convenience wrapper around the app's circuit breaker implementation.
///
/// Providers can use this to fail fast when an endpoint is consistently failing,
/// and to record success/failure signals to close/open the breaker.
enum NetworkCircuitBreaker {
    static func key(for url: URL?, label: String) -> String {
        guard let url else { return label }

        var key = label
        if let scheme = url.scheme {
            key += "|\(scheme)"
        }
        if let host = url.host {
            key += "|\(host)"
        }
        if let port = url.port {
            key += ":\(port)"
        }
        return key
    }

    static func shouldAllowRequest(key: String) -> (allowed: Bool, retryAfterSeconds: TimeInterval?) {
        let breaker = CircuitBreakerRegistry.shared.breaker(for: key)
        guard breaker.shouldAllowRequest else {
            return (false, breaker.timeUntilHalfOpen)
        }
        return (true, nil)
    }

    static func recordSuccess(key: String) {
        CircuitBreakerRegistry.shared.breaker(for: key).recordSuccess()
    }

    static func recordFailure(key: String) {
        CircuitBreakerRegistry.shared.breaker(for: key).recordFailure()
    }

    static func shouldRecordFailure(statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 429:
            true
        case 500 ... 599:
            true
        default:
            false
        }
    }

    static func shouldRecordFailure(error: Error) -> Bool {
        if error is CancellationError { return false }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        return false
    }
}

/// Stateless helper that determines retry behavior for API requests.
/// Implements exponential backoff with jitter for transient failures.
enum OpenAIRetryPolicy {
    // MARK: - Configuration

    struct Config {
        let maxRetries: Int
        let initialDelay: TimeInterval
        let maxDelay: TimeInterval

        nonisolated static let `default` = Config(
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
        try? await Task.sleep(for: .seconds(delaySeconds))
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
