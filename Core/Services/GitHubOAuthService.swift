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

// swiftlint:disable file_length type_body_length

@MainActor
class GitHubOAuthService: NSObject, ObservableObject {
    static let shared = GitHubOAuthService()
    
    // Configuration
    private let clientId = "Iv23liyO8rlOYBXFGZXW"
    private let callbackScheme = "ayna"
    // GitHub Models inference requires 'models:read' scope per docs:
    // https://docs.github.com/en/rest/models/inference
    private let scope = "user:email read:user models:read"
    
    // Published State
    @Published var isAuthenticated = false
    @Published var isAuthenticating = false
    @Published var currentUser: GitHubUser?
    @Published var authError: String?
    @Published var availableModels: [GitHubModel] = []
    @Published var isLoadingModels = false
    @Published var modelsError: String?
    
    // Device Flow State (Legacy/Fallback)
    @Published var deviceCode: DeviceCodeResponse?
    private var pollingTimer: Timer?
    private var presentationContextProvider: ASWebAuthenticationPresentationContextProviding?
    
    // Keychain
    private let keychainKey = "github_oauth_token"
    private let keychainUserKey = "github_user_info"
    
    override init() {
        super.init()
        loadState()
    }
    
    // MARK: - Public API
    
    func getAccessToken() -> String? {
        let token = try? KeychainStorage.shared.string(for: keychainKey)
        DiagnosticsLogger.log(
            .app,
            level: .debug,
            message: "🔑 GitHub OAuth getAccessToken",
            metadata: [
                "hasToken": "\(token != nil)",
                "tokenPrefix": token.map { String($0.prefix(10)) + "..." } ?? "nil"
            ]
        )
        return token
    }
    
    func signOut() {
        try? KeychainStorage.shared.removeValue(for: keychainKey)
        try? KeychainStorage.shared.removeValue(for: keychainUserKey)
        isAuthenticated = false
        currentUser = nil
        availableModels = []
        DiagnosticsLogger.log(.app, level: .info, message: "🚪 Signed out of GitHub")
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
            // Exchange code for token
            let token = try await exchangeCodeForToken(code: code)
            
            // Save token
            try KeychainStorage.shared.setString(token, for: keychainKey)
            
            // Fetch user info
            await fetchUserInfo(token: token)
            
            isAuthenticated = true
            isAuthenticating = false
            
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
    
    private func exchangeCodeForToken(code: String) async throws -> String {
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
                DiagnosticsLogger.log(
                    .app,
                    level: .info,
                    message: "✅ GitHub token exchange successful",
                    metadata: ["tokenPrefix": String(accessToken.prefix(10)) + "..."]
                )
                return accessToken
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
        
        DiagnosticsLogger.log(
            .app,
            level: .info,
            message: "✅ Got device code",
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
        DiagnosticsLogger.log(.app, level: .debug, message: "🔄 Starting polling", metadata: ["interval": "\(interval)"])
        pollingTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.pollForToken()
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
                    DiagnosticsLogger.log(
                        .app,
                        level: .info,
                        message: "✅ GitHub Device Flow successful",
                        metadata: ["tokenPrefix": String(accessToken.prefix(10)) + "..."]
                    )
                    try KeychainStorage.shared.setString(accessToken, for: keychainKey)
                    await fetchUserInfo(token: accessToken)
                    await MainActor.run {
                        self.isAuthenticated = true
                        self.isAuthenticating = false
                        self.deviceCode = nil
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
        isAuthenticating = false
        deviceCode = nil
        authError = nil
    }
    
    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
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
        if let token = try? KeychainStorage.shared.string(for: keychainKey) {
            isAuthenticated = true
            
            if let userData = try? KeychainStorage.shared.data(for: keychainUserKey),
               let user = try? JSONDecoder().decode(GitHubUser.self, from: userData) {
                currentUser = user
            }
            
            // Refresh models on load
            Task {
                await fetchModels()
            }
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

// swiftlint:enable file_length type_body_length

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
