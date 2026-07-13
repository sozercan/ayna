//
//  WebFetchService.swift
//  Ayna
//
//  Cross-platform web fetch tool for fetching URL content.
//  Available on macOS, iOS, and watchOS.
//

import Darwin
import Foundation
import os.log

// MARK: - Host Resolution

/// Injectable hostname-resolution boundary used by request and redirect validation.
struct HostResolver: Sendable {
    static let system = HostResolver { host in
        try await AppleHostResolver.addresses(for: host)
    }

    private let resolve: @Sendable (String) async throws -> [String]

    init(_ resolve: @escaping @Sendable (String) async throws -> [String]) {
        self.resolve = resolve
    }

    func addresses(for host: String) async throws -> [String] {
        try await resolve(host)
    }
}

private enum HostResolutionError: LocalizedError, Sendable {
    case lookupFailed(host: String, code: Int32, message: String)
    case addressConversionFailed(host: String, code: Int32, message: String)
    case noAddresses(host: String)

    var errorDescription: String? {
        switch self {
        case let .lookupFailed(host, code, message):
            "DNS lookup for '\(host)' failed with code \(code): \(message)"
        case let .addressConversionFailed(host, code, message):
            "DNS address conversion for '\(host)' failed with code \(code): \(message)"
        case let .noAddresses(host):
            "DNS lookup for '\(host)' returned no IP addresses"
        }
    }
}

private enum AppleHostResolver {
    static func addresses(for host: String) async throws -> [String] {
        try await Task.detached(priority: .utility) {
            try resolveSynchronously(host)
        }.value
    }

    private static func resolveSynchronously(_ host: String) throws -> [String] {
        let resolved = try resolve(host, family: AF_UNSPEC)
        let originalIPv4 = (try? resolve(host, family: AF_INET)) ?? []
        var seen: Set<String> = []
        return (resolved + originalIPv4).filter { seen.insert($0).inserted }
    }

    private static func resolve(_ host: String, family: Int32) throws -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICSERV
        hints.ai_family = family
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let lookupStatus = host.withCString { hostname in
            getaddrinfo(hostname, nil, &hints, &result)
        }

        guard lookupStatus == 0 else {
            throw HostResolutionError.lookupFailed(
                host: host,
                code: lookupStatus,
                message: errorMessage(for: lookupStatus)
            )
        }

        guard let firstResult = result else {
            throw HostResolutionError.noAddresses(host: host)
        }
        defer { freeaddrinfo(firstResult) }

        var addresses: [String] = []
        var currentResult: UnsafeMutablePointer<addrinfo>? = firstResult
        while let addressInfo = currentResult {
            guard let socketAddress = addressInfo.pointee.ai_addr else {
                throw HostResolutionError.noAddresses(host: host)
            }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let conversionStatus = getnameinfo(
                socketAddress,
                addressInfo.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard conversionStatus == 0 else {
                throw HostResolutionError.addressConversionFailed(
                    host: host,
                    code: conversionStatus,
                    message: errorMessage(for: conversionStatus)
                )
            }

            let addressBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            guard let address = String(bytes: addressBytes, encoding: .utf8) else {
                throw HostResolutionError.addressConversionFailed(
                    host: host,
                    code: EAI_FAIL,
                    message: "Numeric address was not valid UTF-8"
                )
            }
            if !addresses.contains(address) {
                addresses.append(address)
            }
            currentResult = addressInfo.pointee.ai_next
        }

        guard !addresses.isEmpty else {
            throw HostResolutionError.noAddresses(host: host)
        }
        return addresses
    }

    private static func errorMessage(for code: Int32) -> String {
        guard let message = gai_strerror(code) else {
            return "Unknown DNS error"
        }
        return String(cString: message)
    }
}

// MARK: - Request Deadline

private enum WebFetchRequestDeadlineError: LocalizedError, Sendable {
    case timedOut

    var errorDescription: String? {
        "The request timed out."
    }

    var webFetchError: WebFetchError {
        .networkError(underlying: errorDescription ?? "The request timed out.")
    }
}

/// One-shot unstructured race that does not await the losing task during teardown.
/// This is required because the system resolver can remain blocked in `getaddrinfo` after cancellation.
private final class WebFetchDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var outcome: Result<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    func start(
        continuation: CheckedContinuation<Value, Error>,
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async throws -> Value
    ) {
        guard install(continuation) else { return }

        let deadlineTask = Task { [self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            complete(with: .failure(WebFetchRequestDeadlineError.timedOut))
        }
        register(deadlineTask)

        let operationTask = Task { [self] in
            guard clock.now < deadline else {
                complete(with: .failure(WebFetchRequestDeadlineError.timedOut))
                return
            }

            do {
                let value = try await operation()
                guard clock.now < deadline else {
                    complete(with: .failure(WebFetchRequestDeadlineError.timedOut))
                    return
                }
                complete(with: .success(value))
            } catch {
                if clock.now >= deadline {
                    complete(with: .failure(WebFetchRequestDeadlineError.timedOut))
                } else {
                    complete(with: .failure(error))
                }
            }
        }
        register(operationTask)
    }

    func cancel() {
        complete(with: .failure(CancellationError()))
    }

    private func install(_ continuation: CheckedContinuation<Value, Error>) -> Bool {
        let completedOutcome: Result<Value, Error>? = lock.withLock {
            if let outcome {
                return outcome
            }
            self.continuation = continuation
            return nil
        }

        if let completedOutcome {
            continuation.resume(with: completedOutcome)
            return false
        }
        return true
    }

    private func register(_ task: Task<Void, Never>) {
        let shouldCancel = lock.withLock {
            guard outcome == nil else { return true }
            tasks.append(task)
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    private func complete(with outcome: Result<Value, Error>) {
        let completion: (CheckedContinuation<Value, Error>?, [Task<Void, Never>])? = lock.withLock {
            guard self.outcome == nil else { return nil }
            self.outcome = outcome
            let completion = (continuation, tasks)
            continuation = nil
            tasks.removeAll()
            return completion
        }

        guard let completion else { return }
        for task in completion.1 {
            task.cancel()
        }
        completion.0?.resume(with: outcome)
    }
}

private struct WebFetchRequestDeadline: Sendable {
    private let clock: ContinuousClock
    private let instant: ContinuousClock.Instant

    init(timeoutSeconds: TimeInterval) {
        let clock = ContinuousClock()
        self.clock = clock
        instant = clock.now.advanced(by: .seconds(max(0, timeoutSeconds)))
    }

    var remainingTimeInterval: TimeInterval {
        let remaining = clock.now.duration(to: instant)
        guard remaining > .zero else { return 0 }
        let components = remaining.components
        return TimeInterval(components.seconds) +
            TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func check() throws {
        guard clock.now < instant else {
            throw WebFetchRequestDeadlineError.timedOut
        }
    }

    func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try check()

        let race = WebFetchDeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(
                    continuation: continuation,
                    clock: clock,
                    deadline: instant,
                    operation: operation
                )
            }
        } onCancel: {
            race.cancel()
        }
    }
}

// MARK: - Shared SSRF Protection

/// Shared private-host detection used by both redirect validation and fetch-path validation.
enum SSRFProtection {
    /// Checks whether a host string is a loopback, link-local, or private IP address.
    static func isPrivateHost(_ host: String) -> Bool {
        let normalizedHost = normalizedIPAddressCandidate(host)
        if normalizedHost == "localhost" {
            return true
        }

        if let bytes = ipv4Bytes(from: normalizedHost) {
            return isPrivateIPv4(bytes)
        }

        if let bytes = ipv6Bytes(from: normalizedHost) {
            return isPrivateIPv6(bytes)
        }

        return false
    }

    private static func isIPAddress(_ host: String) -> Bool {
        let normalizedHost = normalizedIPAddressCandidate(host)
        return ipv4Bytes(from: normalizedHost) != nil || ipv6Bytes(from: normalizedHost) != nil
    }

    private static func normalizedIPAddressCandidate(_ host: String) -> String {
        var normalizedHost = host.lowercased()
        if normalizedHost.hasPrefix("["), normalizedHost.hasSuffix("]") {
            normalizedHost.removeFirst()
            normalizedHost.removeLast()
        }
        if normalizedHost.contains(":"), let zoneIndex = normalizedHost.firstIndex(of: "%") {
            normalizedHost = String(normalizedHost[..<zoneIndex])
        }
        return normalizedHost
    }

    private static func ipv4Bytes(from addressString: String) -> [UInt8]? {
        var address = in_addr()
        let result = addressString.withCString { inet_pton(AF_INET, $0, &address) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6Bytes(from addressString: String) -> [UInt8]? {
        var address = in6_addr()
        let result = addressString.withCString { inet_pton(AF_INET6, $0, &address) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isPrivateIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        let first = bytes[0]
        let second = bytes[1]

        if first == 0 || first == 10 || first == 127 {
            return true
        }
        if first == 100, (64 ... 127).contains(second) {
            return true
        }
        if first == 169, second == 254 {
            return true
        }
        if first == 172, (16 ... 31).contains(second) {
            return true
        }
        if first == 192, second == 168 {
            return true
        }
        if first == 198, (18 ... 19).contains(second) {
            return true
        }
        return false
    }

    private static func isPrivateIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }

        if bytes.allSatisfy({ $0 == 0 }) {
            return true
        }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return true
        }
        if bytes[0] & 0xFE == 0xFC {
            return true
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            return true
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 {
            return true
        }

        let isWellKnownNAT64 = Array(bytes.prefix(12)) == [
            0x00, 0x64, 0xFF, 0x9B,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ]
        if isWellKnownNAT64 {
            return isPrivateIPv4(Array(bytes.suffix(4)))
        }

        let isLocalUseNAT64 = Array(bytes.prefix(6)) == [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01]
        if isLocalUseNAT64 {
            return true
        }

        let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 } &&
            bytes[10] == 0xFF && bytes[11] == 0xFF
        let isIPv4Compatible = bytes.prefix(12).allSatisfy { $0 == 0 }
        if isIPv4Mapped || isIPv4Compatible {
            return isPrivateIPv4(Array(bytes.suffix(4)))
        }

        return false
    }

    /// Validates a URL's literal host and all resolved IP addresses.
    fileprivate static func validate(
        _ url: URL,
        reportedAs urlString: String,
        using resolver: HostResolver = .system,
        deadline: WebFetchRequestDeadline
    ) async throws {
        guard let host = url.host,
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            throw WebFetchError.invalidURL(url: urlString)
        }

        if isPrivateHost(host) {
            throw WebFetchError.ssrfBlocked(url: urlString)
        }

        let addresses: [String]
        do {
            addresses = try await deadline.perform {
                try await resolver.addresses(for: host)
            }
        } catch let error as WebFetchRequestDeadlineError {
            throw error
        } catch {
            throw resolutionFailure(host: host, reason: error.localizedDescription)
        }

        guard !addresses.isEmpty else {
            throw resolutionFailure(host: host, reason: "No IP addresses returned")
        }

        for address in addresses {
            guard isIPAddress(address) else {
                throw resolutionFailure(host: host, reason: "Resolver returned a non-numeric address: \(address)")
            }
            if isPrivateHost(address) {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .default,
                    message: "🌐 WebFetch: DNS resolution blocked private address",
                    metadata: ["host": host, "ip": address]
                )
                throw WebFetchError.ssrfBlocked(url: urlString)
            }
        }

        try deadline.check()
    }

    static func validateConnectedAddresses(
        _ addresses: [String],
        reportedAs urlString: String,
        isProxyConnection: Bool = false
    ) throws {
        guard !isProxyConnection else {
            throw WebFetchError.networkError(
                underlying: "Connected origin endpoint cannot be verified through a proxy"
            )
        }
        guard !addresses.isEmpty else {
            throw WebFetchError.networkError(
                underlying: "Connected origin endpoint did not report a numeric IP address"
            )
        }
        for address in addresses {
            guard isIPAddress(address) else {
                throw WebFetchError.networkError(
                    underlying: "Connected endpoint was not a numeric IP address: \(address)"
                )
            }
            if isPrivateHost(address) {
                DiagnosticsLogger.log(
                    .aiService,
                    level: .default,
                    message: "🌐 WebFetch: connected endpoint blocked private address",
                    metadata: ["url": urlString, "ip": address]
                )
                throw WebFetchError.ssrfBlocked(url: urlString)
            }
        }
    }

    private static func resolutionFailure(host: String, reason: String) -> WebFetchError {
        .networkError(underlying: "DNS resolution failed for '\(host)': \(reason)")
    }
}

// MARK: - Web Fetch Error

/// Errors that can occur during web fetch
enum WebFetchError: Error, LocalizedError, Sendable {
    case invalidURL(url: String)
    case ssrfBlocked(url: String)
    case httpError(statusCode: Int)
    case responseToLarge(size: Int, limit: Int)
    case binaryContent
    case networkError(underlying: String)
    case serviceDisabled

    var errorDescription: String? {
        switch self {
        case let .invalidURL(url):
            "Invalid URL: \(url)"
        case let .ssrfBlocked(url):
            "Access to internal addresses is not allowed: \(url)"
        case let .httpError(statusCode):
            "HTTP error: \(statusCode)"
        case let .responseToLarge(size, limit):
            "Response too large: \(size) bytes (limit: \(limit) bytes)"
        case .binaryContent:
            "Binary content not supported"
        case let .networkError(underlying):
            "Network error: \(underlying)"
        case .serviceDisabled:
            "Web fetch is disabled"
        }
    }

    /// Structured error message for model consumption
    var modelFacingDescription: String {
        switch self {
        case let .invalidURL(url):
            "ERROR: Invalid URL format '\(url)'. URL must be http:// or https://."
        case let .ssrfBlocked(url):
            "ERROR: Access to internal/private addresses is not allowed: '\(url)'"
        case let .httpError(statusCode):
            "ERROR: HTTP request failed with status code \(statusCode)"
        case let .responseToLarge(size, limit):
            "ERROR: Response too large (\(size / 1024 / 1024) MB). Limit is \(limit / 1024 / 1024) MB."
        case .binaryContent:
            "ERROR: The URL returned binary content. Only text/HTML content is supported."
        case let .networkError(underlying):
            "ERROR: Network request failed: \(underlying)"
        case .serviceDisabled:
            "ERROR: Web fetch is currently disabled. Ask the user to enable it in Settings."
        }
    }
}

// MARK: - SSRF Redirect Protection

private final class RequestValidationState: @unchecked Sendable {
    private let lock = NSLock()
    private var rejection: WebFetchError?
    private var collectedEndpointMetrics = false
    private var isFinished = false

    func record(_ error: WebFetchError) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, rejection == nil else { return }
        rejection = error
    }

    func recordEndpointMetricsCollected() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        collectedEndpointMetrics = true
        lock.unlock()
    }

    func finish() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isFinished
    }

    func recordedExplicitRejection() -> WebFetchError? {
        lock.lock()
        defer { lock.unlock() }
        return rejection
    }

    func recordedRejection(requiresEndpointMetrics: Bool) -> WebFetchError? {
        lock.lock()
        defer { lock.unlock() }
        if let rejection {
            return rejection
        }
        guard requiresEndpointMetrics, !collectedEndpointMetrics else { return nil }
        return .networkError(
            underlying: "Connected origin endpoint metrics were unavailable"
        )
    }
}

/// URLSession delegate that validates redirect targets against private IP ranges.
/// Prevents SSRF bypass via HTTP redirects (e.g., 302 to http://169.254.169.254/).
final class SSRFRedirectValidator: NSObject, URLSessionTaskDelegate, Sendable {
    private let resolver: HostResolver
    private let deadline: WebFetchRequestDeadline
    private let requiresConnectedEndpointVerification: Bool
    private let state = RequestValidationState()

    fileprivate init(
        resolver: HostResolver = .system,
        deadline: WebFetchRequestDeadline,
        requiresConnectedEndpointVerification: Bool = true
    ) {
        self.resolver = resolver
        self.deadline = deadline
        self.requiresConnectedEndpointVerification = requiresConnectedEndpointVerification
    }

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        Task {
            do {
                guard let url = request.url else {
                    throw WebFetchError.invalidURL(url: request.url?.absoluteString ?? "")
                }
                try await SSRFProtection.validate(
                    url,
                    reportedAs: url.absoluteString,
                    using: resolver,
                    deadline: deadline
                )
                completionHandler(state.isActive() ? request : nil)
            } catch let error as WebFetchError {
                state.record(error)
                completionHandler(nil)
            } catch let error as WebFetchRequestDeadlineError {
                state.record(error.webFetchError)
                completionHandler(nil)
            } catch {
                state.record(.networkError(underlying: error.localizedDescription))
                completionHandler(nil)
            }
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard requiresConnectedEndpointVerification else { return }
        state.recordEndpointMetricsCollected()
        let urlString = task.currentRequest?.url?.absoluteString
            ?? task.originalRequest?.url?.absoluteString
            ?? ""
        guard !metrics.transactionMetrics.isEmpty else {
            state.record(.networkError(
                underlying: "Connected origin endpoint metrics contained no transactions"
            ))
            return
        }
        for transaction in metrics.transactionMetrics {
            do {
                try SSRFProtection.validateConnectedAddresses(
                    transaction.remoteAddress.map { [$0] } ?? [],
                    reportedAs: urlString,
                    isProxyConnection: transaction.isProxyConnection
                )
            } catch let error as WebFetchError {
                state.record(error)
                return
            } catch {
                state.record(.networkError(underlying: error.localizedDescription))
                return
            }
        }
    }

    func recordedRejection() -> WebFetchError? {
        state.recordedRejection(
            requiresEndpointMetrics: requiresConnectedEndpointVerification
        )
    }

    func recordedExplicitRejection() -> WebFetchError? {
        state.recordedExplicitRejection()
    }

    func finish() {
        state.finish()
    }
}

// MARK: - Shared Web Fetch Helpers

enum WebTextExtractor {
    private static let scriptRegex = makeRegex("(?is)<script[^>]*>.*?</script>")
    private static let styleRegex = makeRegex("(?is)<style[^>]*>.*?</style>")
    private static let blockElementRegex = makeRegex("(?i)<(br|p|div|h[1-6]|li|tr)[^>]*>")
    private static let tagRegex = makeRegex("<[^>]+>")
    private static let collapsedNewlineRegex = makeRegex("\n{3,}")
    private static let htmlEntities: [(entity: String, replacement: String)] = [
        ("&nbsp;", " "),
        ("&amp;", "&"),
        ("&lt;", "<"),
        ("&gt;", ">"),
        ("&quot;", "\""),
        ("&#39;", "'")
    ]

    static func plainTextIfNeeded(from content: String, contentType: String) -> String {
        let isHTML = contentType.localizedCaseInsensitiveContains("text/html") ||
            content.range(of: "<html", options: .caseInsensitive) != nil

        if isHTML {
            return plainText(fromHTML: content)
        }

        return content
    }

    static func plainText(fromHTML html: String) -> String {
        var text = replace(scriptRegex, in: html, with: "")
        text = replace(styleRegex, in: text, with: "")
        text = replace(blockElementRegex, in: text, with: "\n")
        text = plainText(fromHTMLFragment: text)
        text = replace(collapsedNewlineRegex, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func plainText(fromHTMLFragment htmlFragment: String) -> String {
        let text = replace(tagRegex, in: htmlFragment, with: "")
        return decodeHTMLEntities(in: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(in text: String) -> String {
        htmlEntities.reduce(into: text) { result, entity in
            result = result.replacingOccurrences(of: entity.entity, with: entity.replacement)
        }
    }

    private static func replace(_ regex: NSRegularExpression, in string: String, with template: String) -> String {
        regex.stringByReplacingMatches(
            in: string,
            options: [],
            range: NSRange(string.startIndex..., in: string),
            withTemplate: template
        )
    }

    private static func makeRegex(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid regex pattern: \(pattern)")
        }
    }
}

enum WebFetchRequestExecutor {
    private static let userAgent = "Ayna/1.0"

    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    static func fetchText(
        from urlString: String,
        timeoutSeconds: TimeInterval,
        maxResponseSize: Int,
        session: URLSession = sharedSession,
        resolver: HostResolver = .system,
        requiresConnectedEndpointVerification: Bool = true
    ) async throws -> String {
        let deadline = WebFetchRequestDeadline(timeoutSeconds: timeoutSeconds)

        guard let parsedURL = URL(string: urlString) else {
            throw WebFetchError.invalidURL(url: urlString)
        }

        do {
            try await SSRFProtection.validate(
                parsedURL,
                reportedAs: urlString,
                using: resolver,
                deadline: deadline
            )
        } catch let error as WebFetchRequestDeadlineError {
            throw error.webFetchError
        }

        var request = URLRequest(url: parsedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = max(deadline.remainingTimeInterval, 0.001)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let configuredRequest = request

        let data: Data
        let response: URLResponse
        // URLSession does not expose a pre-connect endpoint hook. Preflight resolution,
        // proxy rejection, and post-transaction endpoint verification are all required before
        // this GET response can be exposed; full IP pinning would require a custom TLS transport.
        let redirectValidator = SSRFRedirectValidator(
            resolver: resolver,
            deadline: deadline,
            requiresConnectedEndpointVerification: requiresConnectedEndpointVerification
        )
        defer { redirectValidator.finish() }
        do {
            (data, response) = try await deadline.perform {
                try await session.data(for: configuredRequest, delegate: redirectValidator)
            }
        } catch let error as WebFetchRequestDeadlineError {
            if let redirectError = redirectValidator.recordedExplicitRejection() {
                throw redirectError
            }
            throw error.webFetchError
        } catch {
            if let redirectError = redirectValidator.recordedRejection() {
                throw redirectError
            }
            throw WebFetchError.networkError(underlying: error.localizedDescription)
        }

        if let redirectError = redirectValidator.recordedRejection() {
            throw redirectError
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.networkError(underlying: "Invalid response")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw WebFetchError.httpError(statusCode: httpResponse.statusCode)
        }

        guard data.count <= maxResponseSize else {
            throw WebFetchError.responseToLarge(size: data.count, limit: maxResponseSize)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw WebFetchError.binaryContent
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        return WebTextExtractor.plainTextIfNeeded(from: content, contentType: contentType)
    }
}

// MARK: - Web Fetch Service

/// Cross-platform service for fetching web content.
/// Available on all platforms (macOS, iOS, watchOS).
@Observable @MainActor
final class WebFetchService {
    // MARK: - Properties

    /// Shared instance
    static let shared = WebFetchService()

    /// Whether the service is enabled
    var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            NotificationCenter.default.post(name: .watchSyncContextDidChange, object: nil)
        }
    }

    /// Timeout for requests in seconds
    var timeoutSeconds: Int = 30

    /// Maximum response size (10 MB)
    private let maxResponseSize: Int = 10 * 1024 * 1024

    /// Tool name constant
    static let toolName = "web_fetch"

    // MARK: - Initialization

    private init() {}

    // MARK: - Web Fetch

    /// Fetches content from a URL and returns it as text.
    ///
    /// - Parameter url: The URL to fetch
    /// - Returns: The page content as plain text
    func fetch(url: String) async throws -> String {
        guard isEnabled else {
            throw WebFetchError.serviceDisabled
        }

        log(.info, "web_fetch requested", metadata: ["url": url])

        let result = try await WebFetchRequestExecutor.fetchText(
            from: url,
            timeoutSeconds: TimeInterval(timeoutSeconds),
            maxResponseSize: maxResponseSize
        )

        log(.info, "web_fetch completed", metadata: ["url": url, "size": "\(result.count)"])
        return result
    }

    // MARK: - Tool Definition

    /// Returns the tool definition in OpenAI function format
    func toolDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": Self.toolName,
                "description": "Fetch content from a URL and return it as plain text. Use for reading web pages, documentation, or API responses. Only HTTP/HTTPS URLs are supported.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The URL to fetch (must be http:// or https://)"
                        ]
                    ] as [String: Any],
                    "required": ["url"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    /// Checks if a tool name is the web_fetch tool
    static func isWebFetchTool(_ name: String) -> Bool {
        name == toolName
    }

    /// Executes a web_fetch tool call and returns the result
    func executeToolCall(arguments: [String: Any]) async -> String {
        guard let url = arguments["url"] as? String else {
            return "ERROR: Missing required parameter 'url'"
        }

        do {
            return try await fetch(url: url)
        } catch let error as WebFetchError {
            return error.modelFacingDescription
        } catch {
            return "ERROR: \(error.localizedDescription)"
        }
    }

    /// Returns context to inject into the system prompt
    func systemPromptContext() -> String? {
        guard isEnabled else { return nil }

        return """
        # Web Fetch Tool

        You have access to the **web_fetch** tool that allows you to fetch content from web URLs.

        When to use this tool:
        - When the user asks to fetch a web page or API response
        - When you need to read documentation from a URL
        - When the user provides a URL and asks about its content

        Limitations:
        - Only HTTP/HTTPS URLs are supported
        - Access to localhost and private IP ranges is blocked for security
        - Maximum response size is 10 MB
        - Binary content is not supported
        """
    }

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: "🌐 WebFetch: \(message)", metadata: metadata)
    }
}
