import Foundation

#if canImport(os)
    import os
#endif

final class CircuitBreaker: @unchecked Sendable {
    enum State: Sendable {
        case closed
        case open(until: Date)
        case halfOpen
    }

    struct Config: Sendable {
        let failureThreshold: Int
        let openDuration: TimeInterval
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

    var state: State {
        lock.lock()
        defer { lock.unlock() }

        if case let .open(until) = _state, Date() >= until {
            _state = .halfOpen
            consecutiveSuccesses = 0
            DiagnosticsLogger.log(
                .aiService,
                level: .info,
                message: "⚡ Circuit breaker transitioning to half-open"
            )
        }
        return _state
    }

    var shouldAllowRequest: Bool {
        switch state {
        case .closed, .halfOpen:
            true
        case .open:
            false
        }
    }

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
                    .aiService,
                    level: .info,
                    message: "✅ Circuit breaker closed after recovery"
                )
            }
        case .closed, .open:
            break
        }
    }

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
                    .aiService,
                    level: .error,
                    message: "🔴 Circuit breaker opened after \(consecutiveFailures) failures",
                    metadata: ["reopensAt": openUntil.description]
                )
            }
        case .halfOpen:
            let openUntil = Date().addingTimeInterval(config.openDuration)
            _state = .open(until: openUntil)
            DiagnosticsLogger.log(
                .aiService,
                level: .error,
                message: "🔴 Circuit breaker reopened after half-open failure"
            )
        case .open:
            break
        }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _state = .closed
        consecutiveFailures = 0
        consecutiveSuccesses = 0
    }

    var timeUntilHalfOpen: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        if case let .open(until) = _state {
            return max(0, until.timeIntervalSinceNow)
        }
        return nil
    }
}

final class CircuitBreakerRegistry: @unchecked Sendable {
    static let shared = CircuitBreakerRegistry()

    private let lock = NSLock()
    private var breakers: [String: CircuitBreaker] = [:]
    private let defaultConfig: CircuitBreaker.Config

    init(config: CircuitBreaker.Config = .default) {
        defaultConfig = config
    }

    func breaker(for endpoint: String) -> CircuitBreaker {
        lock.lock()
        defer { lock.unlock() }

        if let existing = breakers[endpoint] {
            return existing
        }

        if breakers.count > 50, let oldKey = breakers.keys.first {
            breakers.removeValue(forKey: oldKey)
        }

        let newBreaker = CircuitBreaker(config: defaultConfig)
        breakers[endpoint] = newBreaker
        return newBreaker
    }

    func resetAll() {
        lock.lock()
        defer { lock.unlock() }
        breakers.values.forEach { $0.reset() }
        breakers.removeAll()
    }
}

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

struct HTTPStatusError: LocalizedError, Sendable {
    let statusCode: Int
    let message: String
    let retryAfter: Date?

    init(statusCode: Int, message: String, response: HTTPURLResponse? = nil, now: Date = Date()) {
        self.statusCode = statusCode
        self.message = message
        retryAfter = response.flatMap { Self.retryAfterDate(from: $0, now: now) }
    }

    var errorDescription: String? {
        message
    }

    var isRetryable: Bool {
        [408, 409, 429].contains(statusCode) || (500 ... 599).contains(statusCode)
    }

    static func retryAfterDate(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        if let milliseconds = response.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init),
           milliseconds >= 0
        {
            return now.addingTimeInterval(milliseconds / 1000)
        }
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !value.isEmpty
        else {
            return nil
        }
        if let seconds = Double(value), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

enum AIRetryPolicy {
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

    static func shouldRetry(
        error: Error,
        attempt: Int,
        hasReceivedData: Bool = false,
        config: Config = .default
    ) -> Bool {
        guard attempt < config.maxRetries else { return false }

        guard !hasReceivedData else { return false }

        if isCancellationError(error) { return false }

        if let statusError = error as? HTTPStatusError {
            return statusError.isRetryable
        }

        if let urlError = error as? URLError {
            return isRetryableURLError(urlError)
        }

        if let aynaError = error as? AynaError {
            return isRetryableAynaError(aynaError)
        }

        if let openAIError = error as? AIService.AIError {
            return isRetryableAPIError(openAIError)
        }

        return false
    }

    static func retryAfterDate(for error: Error) -> Date? {
        (error as? HTTPStatusError)?.retryAfter
    }

    static func delay(
        for attempt: Int,
        retryAfterDate: Date? = nil,
        config: Config = .default
    ) -> TimeInterval {
        if let retryAfter = retryAfterDate {
            let retryDelay = max(0, retryAfter.timeIntervalSinceNow)
            return min(retryDelay, 60.0)
        }

        let exponentialDelay = config.initialDelay * pow(2.0, Double(attempt))
        let cappedDelay = min(exponentialDelay, config.maxDelay)
        let jitter = Double.random(in: 0 ... 0.1)
        return cappedDelay + jitter
    }

    static func wait(
        for attempt: Int,
        retryAfterDate: Date? = nil,
        config: Config = .default
    ) async {
        let delaySeconds = delay(for: attempt, retryAfterDate: retryAfterDate, config: config)
        try? await Task.sleep(for: .seconds(delaySeconds))
    }

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

    private static func isRetryableAPIError(_ error: AIService.AIError) -> Bool {
        switch error {
        case let .apiError(message):
            let retryableStatusCodes = ["429", "500", "502", "503", "504"]
            return retryableStatusCodes.contains { message.contains($0) }
        default:
            return false
        }
    }

    private static func isRetryableAynaError(_ error: AynaError) -> Bool {
        switch error {
        case let .apiError(message):
            let retryableStatusCodes = ["429", "500", "502", "503", "504"]
            return retryableStatusCodes.contains { message.contains($0) }
        case .rateLimited:
            return true
        case let .httpError(statusCode, _):
            return [408, 409, 429].contains(statusCode) || (500 ... 599).contains(statusCode)
        case .timeout:
            return true
        default:
            return false
        }
    }
}
