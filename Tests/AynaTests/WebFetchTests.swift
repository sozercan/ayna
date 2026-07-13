//
//  WebFetchTests.swift
//  aynaTests
//
//  Unit tests for web_fetch tool functionality via WebFetchService.
//

@testable import Ayna
import Foundation
import Testing

// swiftformat:disable swiftTestingTestCaseNames
@Suite("WebFetch Tests", .serialized)
@MainActor
struct WebFetchTests {
    private var webFetchService: WebFetchService!

    init() {
        webFetchService = WebFetchService.shared
        webFetchService.isEnabled = true
        WebFetchTestURLProtocol.reset()
    }

    // MARK: - Hostname Resolution Tests

    @Test("Rejects a private address reported by the actual connection")
    func rejectsPrivateActualConnectedAddress() throws {
        let url = "https://public-looking.example/private"

        #expect(throws: WebFetchError.self) {
            try SSRFProtection.validateConnectedAddresses(
                ["203.0.113.10", "127.0.0.1"],
                reportedAs: url
            )
        }
        #expect(throws: Never.self) {
            try SSRFProtection.validateConnectedAddresses(
                ["203.0.113.10", "2001:4860:4860::8888"],
                reportedAs: url
            )
        }
        #expect(throws: WebFetchError.self) {
            try SSRFProtection.validateConnectedAddresses([], reportedAs: url)
        }
        #expect(throws: WebFetchError.self) {
            try SSRFProtection.validateConnectedAddresses(
                ["203.0.113.10"],
                reportedAs: url,
                isProxyConnection: true
            )
        }
        #expect(!SSRFProtection.isPrivateHost("64:ff9b::808:808"))
    }

    @Test("Fails closed when hostname resolution fails")
    func failsClosedWhenHostnameResolutionFails() async {
        let url = "https://resolution-failure.example/content"
        let session = makeSession(routes: [url: .success("should not be fetched")])
        let resolver = HostResolver { _ in
            throw WebFetchTestResolverError.lookupFailed
        }

        do {
            _ = try await WebFetchRequestExecutor.fetchText(
                from: url,
                timeoutSeconds: 1,
                maxResponseSize: 1024,
                session: session,
                resolver: resolver,
                requiresConnectedEndpointVerification: false
            )
            Issue.record("Expected DNS resolution failure to stop the request")
        } catch let error as WebFetchError {
            guard case let .networkError(underlying) = error else {
                Issue.record("Expected networkError, got \(error)")
                return
            }
            #expect(underlying.contains("DNS resolution failed"))
            #expect(underlying.contains("resolution-failure.example"))
        } catch {
            Issue.record("Expected WebFetchError, got \(error)")
        }

        #expect(WebFetchTestURLProtocol.requestedURLs.isEmpty)
    }

    @Test("Fails closed when hostname resolution returns no addresses")
    func failsClosedWhenHostnameResolutionReturnsNoAddresses() async {
        let url = "https://no-addresses.example/content"
        let session = makeSession(routes: [url: .success("should not be fetched")])
        let resolver = HostResolver { _ in [] }

        do {
            _ = try await WebFetchRequestExecutor.fetchText(
                from: url,
                timeoutSeconds: 1,
                maxResponseSize: 1024,
                session: session,
                resolver: resolver,
                requiresConnectedEndpointVerification: false
            )
            Issue.record("Expected an empty DNS result to stop the request")
        } catch let error as WebFetchError {
            guard case let .networkError(underlying) = error else {
                Issue.record("Expected networkError, got \(error)")
                return
            }
            #expect(underlying.contains("DNS resolution failed"))
            #expect(underlying.contains("no-addresses.example"))
            #expect(underlying.contains("No IP addresses returned"))
        } catch {
            Issue.record("Expected WebFetchError, got \(error)")
        }

        #expect(WebFetchTestURLProtocol.requestedURLs.isEmpty)
    }

    @Test("Request deadline bounds initial hostname resolution", .timeLimit(.minutes(1)))
    func requestDeadlineBoundsInitialHostnameResolution() async {
        let url = "https://stalled-resolution.example/content"
        let session = makeSession(routes: [url: .success("should not be fetched")])
        let resolverGate = WebFetchTestResolverGate()
        let resolver = HostResolver { _ in
            await resolverGate.resolve()
        }
        let fallbackRelease = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            _ = await resolverGate.succeed(with: ["203.0.113.10"])
        }
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await WebFetchRequestExecutor.fetchText(
                from: url,
                timeoutSeconds: 0.05,
                maxResponseSize: 1024,
                session: session,
                resolver: resolver,
                requiresConnectedEndpointVerification: false
            )
            Issue.record("Expected stalled initial DNS resolution to time out")
        } catch let error as WebFetchError {
            guard case let .networkError(underlying) = error else {
                Issue.record("Expected networkError, got \(error)")
                return
            }
            #expect(underlying.localizedCaseInsensitiveContains("timed out"))
        } catch {
            Issue.record("Expected WebFetchError, got \(error)")
        }

        let elapsed = start.duration(to: clock.now)
        fallbackRelease.cancel()
        if await resolverGate.succeed(with: ["203.0.113.10"]) {
            await resolverGate.waitUntilCompleted()
        }

        #expect(elapsed < .milliseconds(500))
        #expect(WebFetchTestURLProtocol.requestedURLs.isEmpty)
    }

    @Test("Blocks redirects whose hostname resolves to a private address")
    func blocksRedirectResolvingToPrivateAddress() async throws {
        let sourceURL = "https://public-source.example/start"
        let redirectURL = "https://public-looking.example/private"
        let session = try makeSession(routes: [
            sourceURL: .redirect(#require(URL(string: redirectURL))),
            redirectURL: .success("private response")
        ])
        let resolver = HostResolver { host in
            switch host {
            case "public-source.example":
                ["203.0.113.10"]
            case "public-looking.example":
                ["127.0.0.1"]
            default:
                throw WebFetchTestResolverError.unexpectedHost(host)
            }
        }

        do {
            _ = try await WebFetchRequestExecutor.fetchText(
                from: sourceURL,
                timeoutSeconds: 1,
                maxResponseSize: 1024,
                session: session,
                resolver: resolver,
                requiresConnectedEndpointVerification: false
            )
            Issue.record("Expected redirect target to be SSRF-blocked")
        } catch let error as WebFetchError {
            guard case let .ssrfBlocked(url) = error else {
                Issue.record("Expected ssrfBlocked, got \(error)")
                return
            }
            #expect(url == redirectURL)
        } catch {
            Issue.record("Expected WebFetchError, got \(error)")
        }

        #expect(WebFetchTestURLProtocol.requestedURLs == [sourceURL])
    }

    @Test("Blocks hostnames resolving to private addresses", arguments: [
        "127.0.0.1",
        "169.254.20.1",
        "192.168.1.20",
        "::1",
        "fe90::1",
        "fd00::1",
        "::ffff:127.0.0.1",
        "64:ff9b::a00:1",
        "64:ff9b:1::1"
    ])
    func blocksHostnamesResolvingToPrivateAddresses(privateAddress: String) async {
        let url = "https://public-looking.example/content"
        let session = makeSession(routes: [url: .success("private response")])
        let resolver = HostResolver { _ in [privateAddress] }

        do {
            _ = try await WebFetchRequestExecutor.fetchText(
                from: url,
                timeoutSeconds: 1,
                maxResponseSize: 1024,
                session: session,
                resolver: resolver,
                requiresConnectedEndpointVerification: false
            )
            Issue.record("Expected resolved private address \(privateAddress) to be SSRF-blocked")
        } catch let error as WebFetchError {
            guard case let .ssrfBlocked(blockedURL) = error else {
                Issue.record("Expected ssrfBlocked, got \(error)")
                return
            }
            #expect(blockedURL == url)
        } catch {
            Issue.record("Expected WebFetchError, got \(error)")
        }

        #expect(WebFetchTestURLProtocol.requestedURLs.isEmpty)
    }

    @Test("Fails closed when redirect hostname resolution fails")
    func failsClosedWhenRedirectHostnameResolutionFails() async throws {
        let sourceURL = "https://public-source.example/start"
        let redirectURL = "https://resolution-failure.example/content"
        let session = try makeSession(routes: [
            sourceURL: .redirect(#require(URL(string: redirectURL))),
            redirectURL: .success("should not be fetched")
        ])
        let resolver = HostResolver { host in
            if host == "public-source.example" {
                return ["203.0.113.10"]
            }
            throw WebFetchTestResolverError.lookupFailed
        }

        do {
            _ = try await WebFetchRequestExecutor.fetchText(
                from: sourceURL,
                timeoutSeconds: 1,
                maxResponseSize: 1024,
                session: session,
                resolver: resolver,
                requiresConnectedEndpointVerification: false
            )
            Issue.record("Expected redirect DNS resolution failure to stop the request")
        } catch let error as WebFetchError {
            guard case let .networkError(underlying) = error else {
                Issue.record("Expected networkError, got \(error)")
                return
            }
            #expect(underlying.contains("DNS resolution failed"))
            #expect(underlying.contains("resolution-failure.example"))
        } catch {
            Issue.record("Expected WebFetchError, got \(error)")
        }

        #expect(WebFetchTestURLProtocol.requestedURLs == [sourceURL])
    }

    @Test("Request deadline bounds redirect hostname resolution", .timeLimit(.minutes(1)))
    func requestDeadlineBoundsRedirectHostnameResolution() async throws {
        let sourceURL = "https://public-source.example/start"
        let redirectURL = "https://stalled-redirect.example/content"
        let session = try makeSession(routes: [
            sourceURL: .redirect(#require(URL(string: redirectURL))),
            redirectURL: .success("should not be fetched")
        ])
        let resolverGate = WebFetchTestResolverGate()
        let resolver = HostResolver { host in
            switch host {
            case "public-source.example":
                ["203.0.113.10"]
            case "stalled-redirect.example":
                await resolverGate.resolve()
            default:
                throw WebFetchTestResolverError.unexpectedHost(host)
            }
        }
        let fallbackRelease = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            _ = await resolverGate.succeed(with: ["203.0.113.20"])
        }
        let clock = ContinuousClock()
        let start = clock.now

        do {
            _ = try await WebFetchRequestExecutor.fetchText(
                from: sourceURL,
                timeoutSeconds: 0.05,
                maxResponseSize: 1024,
                session: session,
                resolver: resolver,
                requiresConnectedEndpointVerification: false
            )
            Issue.record("Expected stalled redirect DNS resolution to time out")
        } catch let error as WebFetchError {
            guard case let .networkError(underlying) = error else {
                Issue.record("Expected networkError, got \(error)")
                return
            }
            #expect(underlying.localizedCaseInsensitiveContains("timed out"))
        } catch {
            Issue.record("Expected WebFetchError, got \(error)")
        }

        let elapsed = start.duration(to: clock.now)
        fallbackRelease.cancel()
        if await resolverGate.succeed(with: ["203.0.113.20"]) {
            await resolverGate.waitUntilCompleted()
        }

        #expect(elapsed < .milliseconds(500))
        #expect(WebFetchTestURLProtocol.requestedURLs == [sourceURL])
    }

    @Test("Follows redirects whose hostnames resolve only to public addresses")
    func followsPublicRedirects() async throws {
        let sourceURL = "https://public-source.example/start"
        let redirectURL = "https://public-target.example/content"
        let session = try makeSession(routes: [
            sourceURL: .redirect(#require(URL(string: redirectURL))),
            redirectURL: .success("public response")
        ])
        let resolver = HostResolver { host in
            switch host {
            case "public-source.example":
                ["203.0.113.10"]
            case "public-target.example":
                ["203.0.113.20"]
            default:
                throw WebFetchTestResolverError.unexpectedHost(host)
            }
        }

        let result = try await WebFetchRequestExecutor.fetchText(
            from: sourceURL,
            timeoutSeconds: 1,
            maxResponseSize: 1024,
            session: session,
            resolver: resolver,
            requiresConnectedEndpointVerification: false
        )

        #expect(result == "public response")
        #expect(WebFetchTestURLProtocol.requestedURLs == [sourceURL, redirectURL])
    }

    @Test("Completes initial and redirect resolution within one request deadline")
    func completesResolutionWithinRequestDeadline() async throws {
        let sourceURL = "https://public-source.example/start"
        let redirectURL = "https://public-target.example/content"
        let session = try makeSession(routes: [
            sourceURL: .redirect(#require(URL(string: redirectURL))),
            redirectURL: .success("public response")
        ])
        let resolver = HostResolver { host in
            try await Task.sleep(for: .milliseconds(10))
            switch host {
            case "public-source.example":
                return ["203.0.113.10"]
            case "public-target.example":
                return ["203.0.113.20"]
            default:
                throw WebFetchTestResolverError.unexpectedHost(host)
            }
        }

        let result = try await WebFetchRequestExecutor.fetchText(
            from: sourceURL,
            timeoutSeconds: 1,
            maxResponseSize: 1024,
            session: session,
            resolver: resolver,
            requiresConnectedEndpointVerification: false
        )

        #expect(result == "public response")
        #expect(WebFetchTestURLProtocol.requestedURLs == [sourceURL, redirectURL])
    }

    @Test("System resolver resolves a numeric IPv4 address")
    func systemResolverResolvesNumericIPv4Address() async throws {
        let addresses = try await HostResolver.system.addresses(for: "127.0.0.1")
        #expect(addresses.contains("127.0.0.1"))
    }

    // MARK: - Private IP Detection Tests (via fetch errors)

    @Test("Blocks localhost")
    func blocksLocalhost() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://localhost/test")
        }
    }

    @Test("Blocks 127.0.0.1")
    func blocksLoopback() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.0.0.1/test")
        }
    }

    @Test("Blocks 10.x.x.x private range")
    func blocksPrivate10() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://10.0.0.1/test")
        }
    }

    @Test("Blocks 192.168.x.x private range")
    func blocksPrivate192() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://192.168.1.1/test")
        }
    }

    @Test("Blocks 172.16-31.x.x private range")
    func blocksPrivate172() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://172.16.0.1/test")
        }
    }

    @Test("Blocks link-local 169.254.x.x")
    func blocksLinkLocal() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://169.254.1.1/test")
        }
    }

    // MARK: - URL Validation Tests

    @Test("Rejects invalid URL")
    func rejectsInvalidURL() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "not-a-url")
        }
    }

    @Test("Rejects file:// URLs")
    func rejectsFileURL() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "file:///etc/passwd")
        }
    }

    @Test("Rejects ftp:// URLs")
    func rejectsFtpURL() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "ftp://example.com/file")
        }
    }

    // MARK: - Tool Definition Tests

    @Test("WebFetchService tool definition has correct name")
    func webFetchToolDefinitionName() {
        let definition = webFetchService.toolDefinition()
        guard let function = definition["function"] as? [String: Any],
              let name = function["name"] as? String
        else {
            Issue.record("Tool definition missing function or name")
            return
        }
        #expect(name == "web_fetch")
    }

    @Test("web_fetch is recognized by WebFetchService")
    func webFetchIsRecognized() {
        #expect(WebFetchService.isWebFetchTool("web_fetch"))
    }

    // MARK: - Permission Tests

    @Test("web_fetch has automatic permission level")
    func webFetchAutomaticPermission() {
        #expect(PermissionService.defaultPermissionLevel(for: "web_fetch") == .automatic)
    }

    // MARK: - Full Loopback Range Tests

    @Test("Blocks 127.0.0.2")
    func blocksLoopback2() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.0.0.2/test")
        }
    }

    @Test("Blocks 127.1.2.3")
    func blocksLoopback1_2_3() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.1.2.3/test")
        }
    }

    @Test("Blocks 127.255.255.255")
    func blocksLoopbackMax() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://127.255.255.255/test")
        }
    }

    // MARK: - IPv6 False Positive Tests

    /// These verify that domains starting with "fd" or "fc" are NOT blocked.
    /// The SSRF check should only block IPv6 addresses (containing ":"), not hostnames.
    @Test("Does not block fdic.gov (not an IPv6 address)")
    func doesNotBlockFdicGov() {
        #expect(!SSRFProtection.isPrivateHost("fdic.gov"))
    }

    @Test("Does not block fcc.gov (not an IPv6 address)")
    func doesNotBlockFccGov() {
        #expect(!SSRFProtection.isPrivateHost("fcc.gov"))
    }

    // MARK: - IPv6 Private Address Tests

    @Test("Blocks fd00::1 (IPv6 unique local)")
    func blocksIPv6UniqueLocal() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://[fd00::1]/test")
        }
    }

    @Test("Blocks fe80::1 (IPv6 link-local)")
    func blocksIPv6LinkLocal() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://[fe80::1]/test")
        }
    }

    @Test("Blocks fc00::1 (IPv6 unique local fc range)")
    func blocksIPv6UniqueLocalFc() async {
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "http://[fc00::1]/test")
        }
    }

    // MARK: - Service Disabled Tests

    @Test("Throws when service is disabled")
    func throwsWhenDisabled() async {
        webFetchService.isEnabled = false
        defer { webFetchService.isEnabled = true }
        await #expect(throws: WebFetchError.self) {
            _ = try await webFetchService.fetch(url: "https://example.com")
        }
    }

    private func makeSession(routes: [String: WebFetchTestURLProtocol.Response]) -> URLSession {
        WebFetchTestURLProtocol.install(routes: routes)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WebFetchTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private enum WebFetchTestResolverError: LocalizedError, Sendable {
    case lookupFailed
    case unexpectedHost(String)

    var errorDescription: String? {
        switch self {
        case .lookupFailed:
            "Synthetic DNS lookup failure"
        case let .unexpectedHost(host):
            "Unexpected host: \(host)"
        }
    }
}

private actor WebFetchTestResolverGate {
    private var isStarted = false
    private var isCompleted = false
    private var pendingAddresses: [String]?
    private var resolutionContinuation: CheckedContinuation<[String], Never>?
    private var completionWaiters: [CheckedContinuation<Void, Never>] = []

    func resolve() async -> [String] {
        isStarted = true
        let addresses = await withCheckedContinuation { continuation in
            if let pendingAddresses {
                continuation.resume(returning: pendingAddresses)
            } else {
                resolutionContinuation = continuation
            }
        }

        isCompleted = true
        let pendingCompletionWaiters = completionWaiters
        completionWaiters.removeAll()
        for waiter in pendingCompletionWaiters {
            waiter.resume()
        }
        return addresses
    }

    func waitUntilCompleted() async {
        guard !isCompleted else { return }
        await withCheckedContinuation { continuation in
            completionWaiters.append(continuation)
        }
    }

    func succeed(with addresses: [String]) -> Bool {
        guard pendingAddresses == nil else { return isStarted }
        pendingAddresses = addresses
        resolutionContinuation?.resume(returning: addresses)
        resolutionContinuation = nil
        return isStarted
    }
}

private final class WebFetchTestURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response: Sendable {
        case success(String)
        case redirect(URL)
    }

    private static let stateLock = NSLock()
    private nonisolated(unsafe) static var routes: [String: Response] = [:]
    private nonisolated(unsafe) static var recordedURLs: [String] = []

    static var requestedURLs: [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedURLs
    }

    static func install(routes: [String: Response]) {
        stateLock.lock()
        self.routes = routes
        recordedURLs = []
        stateLock.unlock()
    }

    static func reset() {
        install(routes: [:])
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let response: Response?
        Self.stateLock.lock()
        Self.recordedURLs.append(url.absoluteString)
        response = Self.routes[url.absoluteString]
        Self.stateLock.unlock()

        guard let response else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        switch response {
        case let .success(content):
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/plain"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(content.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(target):
            let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
            )!
            client?.urlProtocol(
                self,
                wasRedirectedTo: URLRequest(url: target),
                redirectResponse: httpResponse
            )
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
