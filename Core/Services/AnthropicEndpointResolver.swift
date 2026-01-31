//
//  AnthropicEndpointResolver.swift
//  ayna
//
//  Created on 1/30/26.
//

import Foundation

/// Stateless helper that resolves API endpoint URLs for Anthropic.
/// Handles default and custom endpoints with validation.
enum AnthropicEndpointResolver {
    // MARK: - Default Endpoints

    private static let defaultMessagesURL = "https://api.anthropic.com/v1/messages"

    // MARK: - Public API

    /// Resolves the messages endpoint URL.
    ///
    /// - Parameter customEndpoint: Optional custom endpoint URL.
    /// - Returns: The resolved URL for the messages endpoint.
    /// - Throws: `AynaError.invalidEndpoint` if the URL is malformed or uses HTTP (except localhost).
    static func messagesURL(customEndpoint: String?) throws -> URL {
        guard let customEndpoint, !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let url = URL(string: defaultMessagesURL) else {
                throw AynaError.invalidEndpoint(defaultMessagesURL)
            }
            return url
        }

        let trimmed = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate URL structure
        guard let url = URL(string: trimmed) else {
            throw AynaError.invalidEndpoint(trimmed)
        }

        // Validate scheme
        guard let scheme = url.scheme?.lowercased() else {
            throw AynaError.invalidEndpoint(trimmed)
        }

        // Allow localhost for development testing
        let isLocalhost = url.host?.lowercased() == "localhost" || url.host == "127.0.0.1"

        if scheme == "http", !isLocalhost {
            throw AynaError.invalidEndpoint("HTTP endpoints are not allowed (use HTTPS): \(trimmed)")
        }

        if scheme != "http", scheme != "https" {
            throw AynaError.invalidEndpoint("Invalid URL scheme: \(scheme)")
        }

        // Build the final URL
        let finalURL = appendMessagesPathIfNeeded(trimmed)

        guard let result = URL(string: finalURL) else {
            throw AynaError.invalidEndpoint(finalURL)
        }

        return result
    }

    // MARK: - Private Helpers

    /// Sanitizes a base endpoint by trimming whitespace and trailing slashes.
    private static func sanitizedBaseEndpoint(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Appends `/v1/messages` path if not already present.
    private static func appendMessagesPathIfNeeded(_ endpoint: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(endpoint)
        let messagesPath = "/v1/messages"

        // If the endpoint already ends with /messages or /v1/messages, use as-is
        if cleanBase.hasSuffix("/messages") || cleanBase.hasSuffix("/v1/messages") {
            return cleanBase
        }

        // If it contains /v1/ but not /messages, check if it's complete
        if cleanBase.contains("/v1/") {
            // Already has a path under /v1/, use as-is
            return cleanBase
        }

        return "\(cleanBase)\(messagesPath)"
    }
}
