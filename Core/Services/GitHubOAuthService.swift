//
//  GitHubOAuthService.swift
//  ayna
//
//  Created on 11/27/25.
//

import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import OSLog
import SwiftUI

// MARK: - Token Info Model

/// Stores GitHub OAuth token information including optional refresh token and expiration
struct GitHubTokenInfo: Codable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let scope: String?

    /// Whether the access token has expired
    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }

    /// Whether the access token is expiring within 5 minutes
    var isExpiringSoon: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt.addingTimeInterval(-300) // 5 min buffer
    }

    /// Time remaining until expiration, or nil if no expiration
    var timeUntilExpiration: TimeInterval? {
        guard let expiresAt else { return nil }
        return expiresAt.timeIntervalSinceNow
    }
}

// MARK: - Rate Limit Model

/// GitHub Models rate limit information from API response headers
struct GitHubRateLimitInfo {
    let limit: Int // x-ratelimit-limit
    let remaining: Int // x-ratelimit-remaining
    let resetDate: Date // x-ratelimit-reset (Unix timestamp)
    let resource: String? // x-ratelimit-resource (e.g., "ai-inference")

    /// Whether remaining requests are low (< 20%)
    var isLow: Bool {
        Double(remaining) / Double(max(limit, 1)) < 0.2
    }

    /// Whether rate limit is exhausted
    var isExhausted: Bool { remaining == 0 }

    /// Human-readable reset time
    var formattedReset: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: resetDate, relativeTo: Date())
    }

    /// Parse from HTTP response headers (case-insensitive)
    static func parse(from headers: [AnyHashable: Any]?) -> GitHubRateLimitInfo? {
        guard let headers else { return nil }

        // Helper for case-insensitive lookup
        func header(_ key: String) -> String? {
            let lowercased = key.lowercased()
            for (headerKey, headerValue) in headers {
                if let keyStr = headerKey as? String, keyStr.lowercased() == lowercased {
                    return headerValue as? String
                }
            }
            return nil
        }

        guard let limitStr = header("x-ratelimit-limit"),
              let remainingStr = header("x-ratelimit-remaining"),
              let resetStr = header("x-ratelimit-reset"),
              let limit = Int(limitStr),
              let remaining = Int(remainingStr),
              let resetTimestamp = TimeInterval(resetStr)
        else {
            return nil
        }

        return GitHubRateLimitInfo(
            limit: limit,
            remaining: remaining,
            resetDate: Date(timeIntervalSince1970: resetTimestamp),
            resource: header("x-ratelimit-resource")
        )
    }
}

// MARK: - Concurrency Gate

/// Runs an action at most once.
final class OneShot: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    private let action: @Sendable () -> Void

    nonisolated init(_ action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    nonisolated func run() {
        let shouldRun = state.withLock { didRun -> Bool in
            if didRun {
                return false
            }
            didRun = true
            return true
        }
        if shouldRun {
            action()
        }
    }
}

/// Serializes GitHub Models requests per token identity.
///
/// Purpose: avoid parallel bursts in multi-model mode that trigger 429s.
actor GitHubModelsRequestGate {
    static let shared = GitHubModelsRequestGate()

    private var activeKeys: Set<String> = []
    private var waiters: [String: [(id: UUID, cont: CheckedContinuation<Void, any Error>)]] = [:]

    func acquire(key: String) async throws {
        try Task.checkCancellation()

        if !activeKeys.contains(key) {
            activeKeys.insert(key)
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiters[key, default: []].append((id: id, cont: cont))
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, id: id) }
        }
    }

    func release(key: String) {
        if var queue = waiters[key], !queue.isEmpty {
            let next = queue.removeFirst()
            waiters[key] = queue
            next.cont.resume()
            return
        }

        waiters[key] = nil
        activeKeys.remove(key)
    }

    private func cancelWaiter(key: String, id: UUID) {
        guard var queue = waiters[key] else { return }
        if let index = queue.firstIndex(where: { $0.id == id }) {
            let waiter = queue.remove(at: index)
            waiters[key] = queue.isEmpty ? nil : queue
            waiter.cont.resume(throwing: CancellationError())
        }
    }
}

// MARK: - Auth Errors

enum GitHubAuthError: LocalizedError {
    case noRefreshToken
    case refreshFailed(String)
    case refreshTokenExpired
    case invalidResponse
    case notAuthenticated
    case invalidState
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRefreshToken:
            "No refresh token available. Please sign in again."
        case let .refreshFailed(reason):
            "Failed to refresh token: \(reason)"
        case .refreshTokenExpired:
            "Session expired. Please sign in again."
        case .invalidResponse:
            "Invalid response from GitHub."
        case .notAuthenticated:
            "Not authenticated. Please sign in."
        case .invalidState:
            "Invalid state parameter. Authentication may have been tampered with."
        case let .tokenExchangeFailed(reason):
            "Failed to exchange code for token: \(reason)"
        }
    }
}

@MainActor
class GitHubOAuthService: NSObject, ObservableObject {
    static let shared = GitHubOAuthService()

    /// Injectable for tests. Defaults to the system keychain.
    static var keychain: KeychainStoring = KeychainStorage.shared

    // Configuration
    private let clientId = "Iv23liyO8rlOYBXFGZXW"
    private let tokenExchangeProxyURL = "https://ayna.sozercan.workers.dev/auth/github/exchange"
    private let tokenRefreshProxyURL = "https://ayna.sozercan.workers.dev/auth/github/refresh"

    // Refresh deduplication - prevents multiple concurrent refresh attempts
    private var refreshTask: Task<String, Error>?
    private let callbackScheme = "ayna"
    // GitHub Models inference requires 'models:read' scope per docs:
    // https://docs.github.com/en/rest/models/inference
    private let scope = "user:email read:user models:read"

    // Published State
    @Published var isAuthenticated = false
    @Published var isAuthenticating = false
    @Published var isRefreshing = false
    @Published var currentUser: GitHubUser?
    @Published var authError: String?
    @Published var availableModels: [GitHubModel] = []
    @Published var isLoadingModels = false
    @Published var modelsError: String?
    @Published var tokenExpiresAt: Date?

    // Rate Limit State
    /// Current rate limit info (updated on every GitHub Models API response)
    @Published var rateLimitInfo: GitHubRateLimitInfo?
    /// Retry-After date from a rate limit error (nil if not rate-limited)
    @Published var retryAfterDate: Date?

    private struct RateLimitState: Sendable {
        var info: GitHubRateLimitInfo?
        var retryAfterDate: Date?
    }

    private var rateLimitStateByKey: [String: RateLimitState] = [:]

    // Web Auth Flow State (PKCE)
    private var webAuthSession: ASWebAuthenticationSession?
    private var codeVerifier: String?
    private var authState: String?
    #if !os(watchOS)
        private var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    #endif

    // Keychain Keys
    private let keychainKey = "github_oauth_token" // Legacy, kept for backward compatibility
    private let keychainTokenInfoKey = "github_token_info"
    private let keychainUserKey = "github_user_info"

    override init() {
        super.init()
        loadState()
    }

    // MARK: - Public API

    func getAccessToken() -> String? {
        guard let tokenInfo = loadTokenInfo() else {
            DiagnosticsLogger.log(
                .app,
                level: .debug,
                message: "🔑 GitHub OAuth getAccessToken: no token info"
            )
            return nil
        }

        DiagnosticsLogger.log(
            .app,
            level: .debug,
            message: "🔑 GitHub OAuth getAccessToken",
            metadata: [
                "hasToken": "true",
                "tokenPrefix": String(tokenInfo.accessToken.prefix(10)) + "...",
                "hasRefreshToken": "\(tokenInfo.refreshToken != nil)",
                "isExpiringSoon": "\(tokenInfo.isExpiringSoon)"
            ]
        )

        // Trigger background refresh if expiring soon and we have a refresh token
        // We use getValidAccessToken() inside a Task to handle deduplication correctly
        if tokenInfo.isExpiringSoon, tokenInfo.refreshToken != nil {
            Task {
                try? await getValidAccessToken()
            }
        }

        return tokenInfo.accessToken
    }

    /// Gets a valid access token, refreshing if necessary.
    /// This method deduplicates concurrent refresh requests - multiple callers will share the same refresh operation.
    /// Use this for operations where you can await (preferred over getAccessToken for critical requests).
    func getValidAccessToken() async throws -> String {
        guard let tokenInfo = loadTokenInfo() else {
            throw GitHubAuthError.notAuthenticated
        }

        // If token doesn't expire or isn't expiring soon, return current
        guard tokenInfo.isExpiringSoon else {
            return tokenInfo.accessToken
        }

        // If no refresh token, can't refresh - return current and hope for the best
        guard tokenInfo.refreshToken != nil else {
            DiagnosticsLogger.log(.app, level: .default, message: "⚠️ Token expiring soon but no refresh token available")
            return tokenInfo.accessToken
        }

        // Deduplicate concurrent refresh requests - if a refresh is already in progress, wait for it
        if let existingTask = refreshTask {
            DiagnosticsLogger.log(.app, level: .debug, message: "🔄 Joining existing token refresh task")
            return try await existingTask.value
        }

        // Start a new refresh task
        let task = Task<String, Error> {
            try await performTokenRefresh()
        }
        refreshTask = task

        do {
            let token = try await task.value
            refreshTask = nil
            return token
        } catch {
            refreshTask = nil
            throw error
        }
    }

    func signOut() {
        try? Self.keychain.removeValue(for: keychainTokenInfoKey)
        try? Self.keychain.removeValue(for: keychainKey)
        try? Self.keychain.removeValue(for: keychainUserKey)
        isAuthenticated = false
        currentUser = nil
        tokenExpiresAt = nil
        availableModels = []

        rateLimitStateByKey.removeAll()
        rateLimitInfo = nil
        retryAfterDate = nil

        DiagnosticsLogger.log(.app, level: .info, message: "🚪 Signed out of GitHub")
    }

    /// Set access token received from Watch sync (for watchOS without shared Keychain)
    func setAccessTokenFromWatch(_ token: String) {
        let tokenInfo = GitHubTokenInfo(accessToken: token, refreshToken: nil, expiresAt: nil, scope: nil)
        try? saveTokenInfo(tokenInfo)
        isAuthenticated = true
        DiagnosticsLogger.log(.app, level: .info, message: "🔑 Set GitHub token from Watch sync")
    }

    // MARK: - Token Storage

    private func saveTokenInfo(_ info: GitHubTokenInfo) throws {
        let data = try JSONEncoder().encode(info)
        try Self.keychain.setData(data, for: keychainTokenInfoKey)
        // Also save access token to old key for backward compatibility
        try Self.keychain.setString(info.accessToken, for: keychainKey)

        // Update published state
        tokenExpiresAt = info.expiresAt

        DiagnosticsLogger.log(
            .app,
            level: .debug,
            message: "💾 Saved token info",
            metadata: [
                "hasRefreshToken": "\(info.refreshToken != nil)",
                "expiresAt": info.expiresAt.map { "\($0)" } ?? "never"
            ]
        )
    }

    private func loadTokenInfo() -> GitHubTokenInfo? {
        // Try loading from new key first
        if let data = try? Self.keychain.data(for: keychainTokenInfoKey),
           let info = try? JSONDecoder().decode(GitHubTokenInfo.self, from: data)
        {
            return info
        }

        // Fallback: Try loading from old key (migration path)
        if let token = try? Self.keychain.string(for: keychainKey) {
            DiagnosticsLogger.log(.app, level: .debug, message: "📦 Migrating from legacy token storage")
            return GitHubTokenInfo(accessToken: token, refreshToken: nil, expiresAt: nil, scope: nil)
        }

        return nil
    }

    // MARK: - Token Refresh

    /// Refreshes the access token using the stored refresh token.
    /// For most cases, prefer using `getValidAccessToken()` which handles deduplication.
    /// Returns the new access token on success.
    @discardableResult
    func refreshAccessToken() async throws -> String {
        // Use getValidAccessToken for deduplication if called directly
        try await getValidAccessToken()
    }

    /// Internal method that performs the actual token refresh.
    /// This should only be called from getValidAccessToken() to ensure deduplication.
    private func performTokenRefresh() async throws -> String {
        guard let tokenInfo = loadTokenInfo() else {
            throw GitHubAuthError.notAuthenticated
        }

        guard let refreshToken = tokenInfo.refreshToken else {
            throw GitHubAuthError.noRefreshToken
        }

        await MainActor.run { isRefreshing = true }
        defer { Task { @MainActor in isRefreshing = false } }

        DiagnosticsLogger.log(.app, level: .info, message: "🔄 Refreshing GitHub access token via proxy...")

        let url = URL(string: tokenRefreshProxyURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "refresh_token": refreshToken
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let responseString = String(data: data, encoding: .utf8) ?? ""
        DiagnosticsLogger.log(
            .app,
            level: .debug,
            message: "📦 Token refresh response",
            metadata: ["statusCode": "\(statusCode)", "response": String(responseString.prefix(200))]
        )

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubAuthError.invalidResponse
        }

        // Check for error response
        if let error = json["error"] as? String {
            let errorDescription = json["error_description"] as? String ?? error
            DiagnosticsLogger.log(.app, level: .error, message: "❌ Token refresh failed", metadata: ["error": error, "description": errorDescription])

            if error == "bad_refresh_token" {
                // Refresh token expired or invalid - force re-auth
                await MainActor.run {
                    signOut()
                    authError = "Session expired. Please sign in again."
                }
                throw GitHubAuthError.refreshTokenExpired
            }
            throw GitHubAuthError.refreshFailed(errorDescription)
        }

        guard let newAccessToken = json["access_token"] as? String else {
            throw GitHubAuthError.invalidResponse
        }

        // Parse new token info - refresh token may be rotated
        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken // Keep old if not returned
        let expiresIn = json["expires_in"] as? Int
        let expiresAt = expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
        let scope = json["scope"] as? String

        let newTokenInfo = GitHubTokenInfo(
            accessToken: newAccessToken,
            refreshToken: newRefreshToken,
            expiresAt: expiresAt,
            scope: scope
        )

        try saveTokenInfo(newTokenInfo)

        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "✅ Token refreshed successfully",
            metadata: [
                "tokenPrefix": String(newAccessToken.prefix(10)) + "...",
                "expiresIn": expiresIn.map { "\($0)s" } ?? "never"
            ]
        )

        return newAccessToken
    }

    // MARK: - Rate Limit Management

    nonisolated static func rateLimitKey(forAccessToken accessToken: String) -> String {
        let hash = SHA256.hash(data: Data(accessToken.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    func rateLimitInfo(forAccessToken accessToken: String) -> GitHubRateLimitInfo? {
        rateLimitStateByKey[Self.rateLimitKey(forAccessToken: accessToken)]?.info
    }

    func retryAfterDate(forAccessToken accessToken: String) -> Date? {
        rateLimitStateByKey[Self.rateLimitKey(forAccessToken: accessToken)]?.retryAfterDate
    }

    /// Update rate limit state from API response headers (scoped per access token).
    func updateRateLimit(from response: HTTPURLResponse, forAccessToken accessToken: String) {
        let info = GitHubRateLimitInfo.parse(from: response.allHeaderFields)
        let key = Self.rateLimitKey(forAccessToken: accessToken)
        var state = rateLimitStateByKey[key] ?? RateLimitState()
        state.info = info
        rateLimitStateByKey[key] = state

        // Keep published properties in sync for the currently-active token.
        if loadTokenInfo()?.accessToken == accessToken {
            rateLimitInfo = info
        }

        if let info {
            DiagnosticsLogger.log(
                .app,
                level: .debug,
                message: "📊 Rate limit updated",
                metadata: [
                    "remaining": "\(info.remaining)/\(info.limit)",
                    "resetsIn": info.formattedReset,
                    "resource": info.resource ?? "unknown"
                ]
            )
        }
    }

    /// Backward-compatible overload that updates the current token's state (if available).
    func updateRateLimit(from response: HTTPURLResponse) {
        guard let token = loadTokenInfo()?.accessToken else { return }
        updateRateLimit(from: response, forAccessToken: token)
    }

    /// Update retry-after from 429/403 response (scoped per access token).
    func updateRetryAfter(from response: HTTPURLResponse, forAccessToken accessToken: String) {
        let headers = response.allHeaderFields

        // Case-insensitive lookup for retry-after
        var retryAfterStr: String?
        for (key, value) in headers {
            if let keyStr = key as? String, keyStr.lowercased() == "retry-after",
               let valueStr = value as? String
            {
                retryAfterStr = valueStr
                break
            }
        }

        guard let retryAfter = retryAfterStr else {
            let key = Self.rateLimitKey(forAccessToken: accessToken)
            var state = rateLimitStateByKey[key] ?? RateLimitState()
            state.retryAfterDate = nil
            rateLimitStateByKey[key] = state

            if loadTokenInfo()?.accessToken == accessToken {
                retryAfterDate = nil
            }
            return
        }

        // retry-after can be seconds (integer) or HTTP date
        let retryDate: Date?
        if let seconds = TimeInterval(retryAfter) {
            retryDate = Date().addingTimeInterval(seconds)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            retryDate = formatter.date(from: retryAfter)
        }

        let key = Self.rateLimitKey(forAccessToken: accessToken)
        var state = rateLimitStateByKey[key] ?? RateLimitState()
        state.retryAfterDate = retryDate
        rateLimitStateByKey[key] = state

        if loadTokenInfo()?.accessToken == accessToken {
            retryAfterDate = retryDate
        }

        if let date = retryDate {
            DiagnosticsLogger.log(
                .app,
                level: .default,
                message: "⏳ Rate limit retry-after set",
                metadata: ["retryAt": "\(date)"]
            )
        }
    }

    /// Backward-compatible overload that updates the current token's state (if available).
    func updateRetryAfter(from response: HTTPURLResponse) {
        guard let token = loadTokenInfo()?.accessToken else { return }
        updateRetryAfter(from: response, forAccessToken: token)
    }

    /// Clear retry-after state (call after successful request)
    func clearRetryAfter(forAccessToken accessToken: String) {
        let key = Self.rateLimitKey(forAccessToken: accessToken)
        if rateLimitStateByKey[key]?.retryAfterDate != nil {
            var state = rateLimitStateByKey[key] ?? RateLimitState()
            state.retryAfterDate = nil
            rateLimitStateByKey[key] = state
            if loadTokenInfo()?.accessToken == accessToken {
                retryAfterDate = nil
            }
            DiagnosticsLogger.log(.app, level: .debug, message: "✅ Rate limit cleared")
        }
    }

    func clearRetryAfter() {
        guard let token = loadTokenInfo()?.accessToken else { return }
        clearRetryAfter(forAccessToken: token)
    }

    // MARK: - Authorization Code Flow (Web) with PKCE

    #if !os(watchOS)
        func startWebFlow(contextProvider: (any ASWebAuthenticationPresentationContextProviding)? = nil) {
            // Cancel any existing auth flow before starting new one to prevent state mismatch
            cancelAuthentication()

            let resolvedContextProvider = contextProvider ?? DefaultPresentationContextProvider()

            presentationContextProvider = resolvedContextProvider
            isAuthenticating = true
            authError = nil

            // 1. Generate PKCE code verifier and challenge
            let verifier = generateCodeVerifier()
            codeVerifier = verifier
            let challenge = generateCodeChallenge(verifier: verifier)

            // 2. Generate state for CSRF protection
            let state = UUID().uuidString
            authState = state

            DiagnosticsLogger.log(
                .app,
                level: .debug,
                message: "🔐 Starting GitHub Web Flow with PKCE",
                metadata: ["challengeLength": "\(challenge.count)", "stateLength": "\(state.count)"]
            )

            // 3. Construct authorization URL
            var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: clientId),
                URLQueryItem(name: "scope", value: scope),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]

            guard let url = components.url else {
                authError = "Failed to build auth URL"
                isAuthenticating = false
                return
            }

            // 4. Create and start ASWebAuthenticationSession
            let session = createWebAuthSession(url: url, callbackScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.handleWebAuthResult(callbackURL: callbackURL, error: error)
            }

            // Store session to prevent deallocation
            webAuthSession = session
            session.presentationContextProvider = resolvedContextProvider
            session.prefersEphemeralWebBrowserSession = false // Allow SSO

            if !session.start() {
                authError = "Failed to start authentication session"
                isAuthenticating = false
                clearPKCEState()
            }
        }
    #endif

    // MARK: - PKCE Helpers

    /// Generates a cryptographically random code verifier (43-128 chars, base64url)
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Generates code challenge from verifier using SHA256
    private func generateCodeChallenge(verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Clears PKCE state after auth completes or is cancelled
    private func clearPKCEState() {
        codeVerifier = nil
        authState = nil
        webAuthSession = nil
    }

    private func handleWebAuthResult(callbackURL: URL?, error: Error?) {
        if let error {
            // ASWebAuthenticationSessionError.canceledLogin is common
            if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                isAuthenticating = false
                clearPKCEState()
                return
            }
            authError = error.localizedDescription
            isAuthenticating = false
            clearPKCEState()
            return
        }

        guard let callbackURL else {
            authError = "No callback URL"
            isAuthenticating = false
            clearPKCEState()
            return
        }

        Task {
            await self.handleCallbackURL(callbackURL)
        }
    }

    private nonisolated func createWebAuthSession(
        url: URL,
        callbackScheme: String,
        completion: @escaping @MainActor @Sendable (URL?, Error?) -> Void
    ) -> ASWebAuthenticationSession {
        ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
            Task { @MainActor in
                completion(callbackURL, error)
            }
        }
    }

    func handleCallbackURL(_ url: URL) async {
        // Parse code and state from URL: ayna://oauth/callback?code=...&state=...
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            authError = "No authorization code in callback"
            isAuthenticating = false
            clearPKCEState()
            return
        }

        // Validate state parameter for CSRF protection
        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        guard returnedState == authState else {
            DiagnosticsLogger.log(
                .app,
                level: .error,
                message: "❌ State mismatch in OAuth callback",
                metadata: ["expected": authState ?? "nil", "received": returnedState ?? "nil"]
            )
            authError = GitHubAuthError.invalidState.localizedDescription
            isAuthenticating = false
            clearPKCEState()
            return
        }

        isAuthenticating = true

        do {
            // Exchange code for token via proxy (includes code_verifier for PKCE)
            let tokenInfo = try await exchangeCodeForToken(code: code)

            // Clear PKCE state after successful exchange
            clearPKCEState()

            // Save token info
            try saveTokenInfo(tokenInfo)

            // Fetch user info
            await fetchUserInfo(token: tokenInfo.accessToken)

            isAuthenticated = true
            isAuthenticating = false
            tokenExpiresAt = tokenInfo.expiresAt

            // Fetch models in the background
            Task {
                await fetchModels()
            }

            DiagnosticsLogger.log(.app, level: .info, message: "✅ GitHub Web Auth Successful")

        } catch {
            authError = error.localizedDescription
            isAuthenticating = false
            clearPKCEState()
            DiagnosticsLogger.log(.app, level: .error, message: "❌ GitHub Web Auth Failed", metadata: ["error": error.localizedDescription])
        }
    }

    private func exchangeCodeForToken(code: String) async throws -> GitHubTokenInfo {
        guard let verifier = codeVerifier else {
            throw GitHubAuthError.tokenExchangeFailed("Missing code verifier")
        }

        let url = URL(string: tokenExchangeProxyURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Send code and code_verifier to proxy (proxy adds client_id and client_secret)
        let body: [String: String] = [
            "code": code,
            "code_verifier": verifier
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Log the response for debugging
        let responseString = String(data: data, encoding: .utf8) ?? "nil"
        DiagnosticsLogger.log(
            .app,
            level: .debug,
            message: "🔑 GitHub token exchange response",
            metadata: [
                "statusCode": "\((response as? HTTPURLResponse)?.statusCode ?? 0)",
                "responsePreview": String(responseString.prefix(200))
            ]
        )

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GitHubAuthError.invalidResponse
        }

        if let error = json["error"] as? String {
            let errorDescription = json["error_description"] as? String ?? error
            throw GitHubAuthError.tokenExchangeFailed(errorDescription)
        }

        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw GitHubAuthError.tokenExchangeFailed("No access token in response")
        }

        // Parse optional expiration fields
        let expiresIn = json["expires_in"] as? Int
        let refreshToken = json["refresh_token"] as? String
        let scope = json["scope"] as? String
        let expiresAt = expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }

        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "✅ GitHub token exchange successful",
            metadata: [
                "tokenPrefix": String(accessToken.prefix(10)) + "...",
                "hasRefreshToken": "\(refreshToken != nil)",
                "expiresIn": expiresIn.map { "\($0)s" } ?? "never"
            ]
        )

        return GitHubTokenInfo(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scope: scope
        )
    }

    func cancelAuthentication() {
        webAuthSession?.cancel()
        clearPKCEState()
        isAuthenticating = false
        authError = nil
    }

    // MARK: - User Info

    private func fetchUserInfo(token: String) async {
        let url = URL(string: "https://api.github.com/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let user = try JSONDecoder().decode(GitHubUser.self, from: data)

            // Save user info
            if let userData = try? JSONEncoder().encode(user) {
                try Self.keychain.setData(userData, for: keychainUserKey)
            }

            await MainActor.run {
                self.currentUser = user
            }
        } catch {
            DiagnosticsLogger.log(
                .openAIService,
                level: .error,
                message: "Failed to fetch GitHub user info",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func loadState() {
        guard let tokenInfo = loadTokenInfo() else { return }

        isAuthenticated = true
        tokenExpiresAt = tokenInfo.expiresAt

        // Load user info from keychain
        if let userData = try? Self.keychain.data(for: keychainUserKey),
           let user = try? JSONDecoder().decode(GitHubUser.self, from: userData)
        {
            currentUser = user
        }

        // Check if token needs refresh on launch
        if tokenInfo.isExpiringSoon, tokenInfo.refreshToken != nil {
            DiagnosticsLogger.log(.app, level: .info, message: "🔄 Token expiring soon, refreshing on startup...")
            Task {
                do {
                    _ = try await refreshAccessToken()
                } catch {
                    DiagnosticsLogger.log(.app, level: .error, message: "❌ Startup token refresh failed: \(error.localizedDescription)")
                }
            }
        }

        // Refresh models on load
        Task {
            await fetchModels()
        }
    }

    // MARK: - Models

    func fetchModels() async {
        guard let token = getAccessToken() else {
            await MainActor.run {
                self.modelsError = "Authentication required"
            }
            return
        }

        await MainActor.run {
            self.isLoadingModels = true
            self.modelsError = nil
        }

        // GitHub Models catalog API endpoint
        let url = URL(string: "https://models.github.ai/catalog/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 200 {
                    // Log raw response for debugging
                    if let jsonString = String(data: data, encoding: .utf8) {
                        DiagnosticsLogger.log(.app, level: .debug, message: "📦 Raw API response", metadata: ["response": String(jsonString.prefix(500))])
                    }

                    // Try to decode the response
                    do {
                        let models = try JSONDecoder().decode([GitHubModel].self, from: data)
                        await MainActor.run {
                            self.availableModels = models.sorted { $0.displayName < $1.displayName }
                            self.isLoadingModels = false
                            self.modelsError = nil
                            DiagnosticsLogger.log(.app, level: .info, message: "✅ Fetched \(models.count) GitHub models")
                        }
                    } catch let decodingError {
                        // Decoding failed - show the actual structure
                        let errorMessage: String
                        if let json = try? JSONSerialization.jsonObject(with: data) {
                            errorMessage = "Response structure mismatch. Decoding error: \(decodingError.localizedDescription)"
                            DiagnosticsLogger.log(.app, level: .error, message: "❌ Decoding failed", metadata: ["error": decodingError.localizedDescription, "structure": "\(json)"])
                        } else {
                            errorMessage = "Invalid JSON response: \(decodingError.localizedDescription)"
                        }
                        await MainActor.run {
                            self.isLoadingModels = false
                            self.modelsError = errorMessage
                        }
                    }
                } else {
                    let errorMessage: String = if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                                  let message = json["message"] as? String
                    {
                        message
                    } else if let responseText = String(data: data, encoding: .utf8) {
                        "HTTP \(httpResponse.statusCode): \(responseText.prefix(200))"
                    } else {
                        "HTTP \(httpResponse.statusCode)"
                    }
                    await MainActor.run {
                        self.isLoadingModels = false
                        self.modelsError = errorMessage
                        DiagnosticsLogger.log(.app, level: .error, message: "❌ Failed to fetch models", metadata: ["error": errorMessage])
                    }
                }
            }
        } catch {
            await MainActor.run {
                self.isLoadingModels = false
                self.modelsError = error.localizedDescription
                DiagnosticsLogger.log(.app, level: .error, message: "❌ Error fetching models", metadata: ["error": error.localizedDescription])
            }
        }
    }
}

// MARK: - Models

struct GitHubUser: Codable {
    let login: String
    let name: String?
    let avatarUrl: String?

    enum CodingKeys: String, CodingKey {
        case login
        case name
        case avatarUrl = "avatar_url"
    }
}

struct GitHubModel: Codable, Identifiable {
    let id: String
    let name: String
    let publisher: String
    let registry: String?
    let summary: String?
    let htmlUrl: String?
    let version: String?
    let capabilities: [String]?
    let tags: [String]?

    var displayName: String {
        name
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case publisher
        case registry
        case summary
        case htmlUrl = "html_url"
        case version
        case capabilities
        case tags
    }
}

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

#if !os(watchOS)
    class DefaultPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
        func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
            #if os(macOS)
                return NSApp.windows.first ?? ASPresentationAnchor()
            #elseif os(iOS)
                return UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first { $0.isKeyWindow } ?? ASPresentationAnchor()
            #endif
        }
    }
#endif

// MARK: - Rate Limit Warning Banner

#if !os(watchOS)
    /// Warning banner shown when GitHub Models rate limit is low or exhausted
    struct RateLimitWarningBanner: View {
        let rateLimitInfo: GitHubRateLimitInfo?
        let retryAfterDate: Date?

        var body: some View {
            if let retryAfter = retryAfterDate, retryAfter > Date() {
                // Actively rate-limited
                warningBanner(
                    icon: "exclamationmark.triangle.fill",
                    message: "Rate limited. Retry \(formatRetryAfter(retryAfter)).",
                    color: .red
                )
            } else if let info = rateLimitInfo, info.isExhausted {
                // Exhausted
                warningBanner(
                    icon: "xmark.circle.fill",
                    message: "Rate limit reached. Resets \(info.formattedReset).",
                    color: .red
                )
            } else if let info = rateLimitInfo, info.isLow {
                // Low
                warningBanner(
                    icon: "exclamationmark.circle.fill",
                    message: "\(info.remaining)/\(info.limit) requests remaining. Resets \(info.formattedReset).",
                    color: .orange
                )
            }
        }

        @ViewBuilder
        private func warningBanner(icon: String, message: String, color: Color) -> some View {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .accessibilityIdentifier(TestIdentifiers.RateLimit.warningIcon)
                Text(message)
                    .font(.caption)
                    .accessibilityIdentifier(TestIdentifiers.RateLimit.warningMessage)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(color.opacity(0.1))
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityIdentifier(TestIdentifiers.RateLimit.warningBanner)
        }

        private func formatRetryAfter(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return formatter.localizedString(for: date, relativeTo: Date())
        }
    }
#endif
