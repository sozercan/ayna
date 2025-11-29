//
//  GitHubOAuthService.swift
//  ayna
//
//  Created on 11/27/25.
//

import AuthenticationServices
import Combine
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
    let limit: Int           // x-ratelimit-limit
    let remaining: Int       // x-ratelimit-remaining
    let resetDate: Date      // x-ratelimit-reset (Unix timestamp)
    let resource: String?    // x-ratelimit-resource (e.g., "ai-inference")
    
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
        guard let headers = headers else { return nil }
        
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
              let resetTimestamp = TimeInterval(resetStr) else {
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

// MARK: - Auth Errors

enum GitHubAuthError: LocalizedError {
    case noRefreshToken
    case refreshFailed(String)
    case refreshTokenExpired
    case invalidResponse
    case notAuthenticated
    
    var errorDescription: String? {
        switch self {
        case .noRefreshToken:
            return "No refresh token available. Please sign in again."
        case .refreshFailed(let reason):
            return "Failed to refresh token: \(reason)"
        case .refreshTokenExpired:
            return "Session expired. Please sign in again."
        case .invalidResponse:
            return "Invalid response from GitHub."
        case .notAuthenticated:
            return "Not authenticated. Please sign in."
        }
    }
}

@MainActor
class GitHubOAuthService: NSObject, ObservableObject {
    static let shared = GitHubOAuthService()
    
    // Configuration
    private let clientId = "Iv23liyO8rlOYBXFGZXW"
    
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
    
    // Device Flow State (Legacy/Fallback)
    @Published var deviceCode: DeviceCodeResponse?
    private var pollingTimer: Timer?
    private var pollingStartTime: Date?
    /// Maximum duration for device flow polling (GitHub device codes expire after 15 minutes)
    private let maxPollingDuration: TimeInterval = 900
    private var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    
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
        try? KeychainStorage.shared.removeValue(for: keychainTokenInfoKey)
        try? KeychainStorage.shared.removeValue(for: keychainKey)
        try? KeychainStorage.shared.removeValue(for: keychainUserKey)
        isAuthenticated = false
        currentUser = nil
        tokenExpiresAt = nil
        availableModels = []
        DiagnosticsLogger.log(.app, level: .info, message: "🚪 Signed out of GitHub")
    }
    
    // MARK: - Token Storage
    
    private func saveTokenInfo(_ info: GitHubTokenInfo) throws {
        let data = try JSONEncoder().encode(info)
        try KeychainStorage.shared.setData(data, for: keychainTokenInfoKey)
        // Also save access token to old key for backward compatibility
        try KeychainStorage.shared.setString(info.accessToken, for: keychainKey)
        
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
        if let data = try? KeychainStorage.shared.data(for: keychainTokenInfoKey),
           let info = try? JSONDecoder().decode(GitHubTokenInfo.self, from: data) {
            return info
        }
        
        // Fallback: Try loading from old key (migration path)
        if let token = try? KeychainStorage.shared.string(for: keychainKey) {
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
        return try await getValidAccessToken()
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
        
        DiagnosticsLogger.log(.app, level: .info, message: "🔄 Refreshing GitHub access token...")
        
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Device Flow doesn't require client_secret for refresh
        let body = "client_id=\(clientId)&grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)
        
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
    
    /// Update rate limit state from API response headers
    func updateRateLimit(from response: HTTPURLResponse) {
        let info = GitHubRateLimitInfo.parse(from: response.allHeaderFields)
        rateLimitInfo = info
        
        if let info = info {
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
    
    /// Update retry-after from 429/403 response
    func updateRetryAfter(from response: HTTPURLResponse) {
        let headers = response.allHeaderFields
        
        // Case-insensitive lookup for retry-after
        var retryAfterStr: String?
        for (key, value) in headers {
            if let keyStr = key as? String, keyStr.lowercased() == "retry-after",
               let valueStr = value as? String {
                retryAfterStr = valueStr
                break
            }
        }
        
        guard let retryAfter = retryAfterStr else {
            retryAfterDate = nil
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
        
        retryAfterDate = retryDate
        
        if let date = retryDate {
            DiagnosticsLogger.log(
                .app,
                level: .default,
                message: "⏳ Rate limit retry-after set",
                metadata: ["retryAt": "\(date)"]
            )
        }
    }
    
    /// Clear retry-after state (call after successful request)
    func clearRetryAfter() {
        if retryAfterDate != nil {
            retryAfterDate = nil
            DiagnosticsLogger.log(.app, level: .debug, message: "✅ Rate limit cleared")
        }
    }
    
    // MARK: - Authorization Code Flow (Web)
    
    func startWebFlow(contextProvider: ASWebAuthenticationPresentationContextProviding = DefaultPresentationContextProvider()) {
        self.presentationContextProvider = contextProvider
        isAuthenticating = true
        authError = nil
        
        // 1. Construct URL
        // https://github.com/login/oauth/authorize
        var components = URLComponents(string: "https://github.com/login/oauth/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        
        guard let url = components.url else {
            authError = "Failed to build auth URL"
            isAuthenticating = false
            return
        }
        
        // 2. Start Session
        let session = createWebAuthSession(url: url, callbackScheme: callbackScheme) { [weak self] callbackURL, error in
            self?.handleWebAuthResult(callbackURL: callbackURL, error: error)
        }
        
        session.presentationContextProvider = contextProvider
        session.start()
    }
    
    private func handleWebAuthResult(callbackURL: URL?, error: Error?) {
        if let error = error {
            // ASWebAuthenticationSessionError.canceledLogin is common
            if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                self.isAuthenticating = false
                return
            }
            self.authError = error.localizedDescription
            self.isAuthenticating = false
            return
        }
        
        guard let callbackURL = callbackURL else {
            self.authError = "No callback URL"
            self.isAuthenticating = false
            return
        }
        
        Task {
            await self.handleCallbackURL(callbackURL)
        }
    }
    
    nonisolated private func createWebAuthSession(
        url: URL,
        callbackScheme: String,
        completion: @escaping @MainActor @Sendable (URL?, Error?) -> Void
    ) -> ASWebAuthenticationSession {
        return ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
            Task { @MainActor in
                completion(callbackURL, error)
            }
        }
    }
    
    func handleCallbackURL(_ url: URL) async {
        // Parse code from URL: ayna://?code=...
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            return
        }
        
        isAuthenticating = true
        
        do {
            // Exchange code for token (returns GitHubTokenInfo now)
            let tokenInfo = try await exchangeCodeForToken(code: code)
            
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
            DiagnosticsLogger.log(.app, level: .error, message: "❌ GitHub Web Auth Failed", metadata: ["error": error.localizedDescription])
        }
    }
    
    private func exchangeCodeForToken(code: String) async throws -> GitHubTokenInfo {
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // GitHub OAuth can exchange code with just client_id for public native apps
        let body: [String: String] = [
            "client_id": clientId,
            "code": code
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
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? String {
                let errorDescription = json["error_description"] as? String ?? error
                throw NSError(domain: "GitHubOAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: errorDescription])
            }
            
            if let accessToken = json["access_token"] as? String, !accessToken.isEmpty {
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
        }
        
        throw NSError(domain: "GitHubOAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: "No access token in response"])
    }
    
    // MARK: - Device Flow (Robust)
    
    func startDeviceFlow() async throws -> DeviceCodeResponse {
        isAuthenticating = true
        authError = nil
        
        DiagnosticsLogger.log(.app, level: .info, message: "🔐 Starting GitHub Device Flow")
        
        // 1. Request Device Code
        let url = URL(string: "https://github.com/login/device/code")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "client_id": clientId,
            "scope": scope
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        let responseString = String(data: data, encoding: .utf8) ?? "nil"
        DiagnosticsLogger.log(
            .app,
            level: .debug,
            message: "📦 Device code response",
            metadata: [
                "statusCode": "\((response as? HTTPURLResponse)?.statusCode ?? 0)",
                "responsePreview": String(responseString.prefix(200))
            ]
        )
        
        let deviceResponse = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        
        self.deviceCode = deviceResponse
        
        // Auto-copy user code to clipboard for convenience
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(deviceResponse.userCode, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = deviceResponse.userCode
        #endif
        
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "✅ Got device code (copied to clipboard)",
            metadata: [
                "userCode": deviceResponse.userCode,
                "verificationUri": deviceResponse.verificationUri
            ]
        )
        
        // 2. Start Polling
        startPolling(interval: deviceResponse.interval)
        
        return deviceResponse
    }
    
    private func startPolling(interval: Int) {
        pollingTimer?.invalidate()
        
        // Track when polling started (only set on first call, not on interval changes)
        if pollingStartTime == nil {
            pollingStartTime = Date()
        }
        
        DiagnosticsLogger.log(.app, level: .debug, message: "🔄 Starting polling", metadata: ["interval": "\(interval)"])
        pollingTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            
            // Check for polling timeout
            if let start = self.pollingStartTime,
               Date().timeIntervalSince(start) > self.maxPollingDuration {
                DiagnosticsLogger.log(.app, level: .default, message: "⏰ Device flow polling timed out after 15 minutes")
                Task { @MainActor in
                    self.stopPolling()
                    self.authError = "Authentication timed out. Please try again."
                    self.isAuthenticating = false
                    self.deviceCode = nil
                }
                return
            }
            
            Task { @MainActor in
                await self.pollForToken()
            }
        }
    }
    
    private func pollForToken() async {
        guard let deviceCode = deviceCode?.deviceCode else {
            DiagnosticsLogger.log(.app, level: .error, message: "❌ No device code for polling")
            return
        }
        
        DiagnosticsLogger.log(.app, level: .debug, message: "🔄 Polling for token...")
        
        let url = URL(string: "https://github.com/login/oauth/access_token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "client_id": clientId,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseString = String(data: data, encoding: .utf8) ?? ""
            DiagnosticsLogger.log(
                .app,
                level: .debug,
                message: "📦 Poll response",
                metadata: ["statusCode": "\(statusCode)", "response": String(responseString.prefix(200))]
            )
            
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let error = json["error"] as? String {
                    if error == "authorization_pending" {
                        // Continue polling - user hasn't authorized yet
                        DiagnosticsLogger.log(.app, level: .debug, message: "⏳ Authorization pending...")
                        return
                    } else if error == "slow_down" {
                        // GitHub is asking us to slow down - restart polling with new interval
                        let newInterval = json["interval"] as? Int ?? 10
                        DiagnosticsLogger.log(.app, level: .default, message: "⚠️ Slow down requested, increasing interval", metadata: ["newInterval": "\(newInterval)"])
                        startPolling(interval: newInterval)
                        return
                    } else {
                        // Fatal error
                        DiagnosticsLogger.log(.app, level: .error, message: "❌ Polling error: \(error)")
                        stopPolling()
                        await MainActor.run {
                            self.authError = error
                            self.isAuthenticating = false
                        }
                        return
                    }
                }
                
                if let accessToken = json["access_token"] as? String {
                    stopPolling()
                    
                    // Parse optional expiration fields (present if token expiration is enabled on GitHub App)
                    let expiresIn = json["expires_in"] as? Int
                    let refreshToken = json["refresh_token"] as? String
                    let scope = json["scope"] as? String
                    let expiresAt = expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }
                    
                    let tokenInfo = GitHubTokenInfo(
                        accessToken: accessToken,
                        refreshToken: refreshToken,
                        expiresAt: expiresAt,
                        scope: scope
                    )
                    
                    DiagnosticsLogger.log(
                        .app,
                        level: .info,
                        message: "✅ GitHub Device Flow successful",
                        metadata: [
                            "tokenPrefix": String(accessToken.prefix(10)) + "...",
                            "hasRefreshToken": "\(refreshToken != nil)",
                            "expiresIn": expiresIn.map { "\($0)s" } ?? "never"
                        ]
                    )
                    
                    try saveTokenInfo(tokenInfo)
                    await fetchUserInfo(token: accessToken)
                    await MainActor.run {
                        self.isAuthenticated = true
                        self.isAuthenticating = false
                        self.deviceCode = nil
                        self.tokenExpiresAt = expiresAt
                    }
                    // Fetch models in the background after authentication
                    Task {
                        await self.fetchModels()
                    }
                }
            }
        } catch {
            DiagnosticsLogger.log(.app, level: .error, message: "❌ Polling network error: \(error.localizedDescription)")
        }
    }
    
    func cancelAuthentication() {
        stopPolling()
        pollingStartTime = nil
        isAuthenticating = false
        deviceCode = nil
        authError = nil
    }
    
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
        pollingStartTime = nil
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
                try KeychainStorage.shared.setData(userData, for: keychainUserKey)
            }
            
            await MainActor.run {
                self.currentUser = user
            }
        } catch {
            print("Failed to fetch user info: \(error)")
        }
    }
    
    private func loadState() {
        guard let tokenInfo = loadTokenInfo() else { return }
        
        isAuthenticated = true
        tokenExpiresAt = tokenInfo.expiresAt
        
        // Load user info from keychain
        if let userData = try? KeychainStorage.shared.data(for: keychainUserKey),
           let user = try? JSONDecoder().decode(GitHubUser.self, from: userData) {
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
                    let errorMessage: String
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let message = json["message"] as? String {
                        errorMessage = message
                    } else if let responseText = String(data: data, encoding: .utf8) {
                        errorMessage = "HTTP \(httpResponse.statusCode): \(responseText.prefix(200))"
                    } else {
                        errorMessage = "HTTP \(httpResponse.statusCode)"
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

struct DeviceCodeResponse: Codable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let expiresIn: Int
    let interval: Int
    
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

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

class DefaultPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApp.windows.first ?? ASPresentationAnchor()
        #elseif os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}

// MARK: - Rate Limit Warning Banner

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
                .foregroundColor(color)
                .accessibilityIdentifier(TestIdentifiers.RateLimit.warningIcon)
            Text(message)
                .font(.caption)
                .accessibilityIdentifier(TestIdentifiers.RateLimit.warningMessage)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .cornerRadius(8)
        .accessibilityIdentifier(TestIdentifiers.RateLimit.warningBanner)
    }
    
    private func formatRetryAfter(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
