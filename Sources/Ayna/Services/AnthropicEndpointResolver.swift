import Foundation

enum AnthropicEndpointResolver {
    private static let defaultMessagesURL = "https://api.anthropic.com/v1/messages"

    static func messagesURL(customEndpoint: String?) throws -> URL {
        guard let customEndpoint, !customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            guard let url = URL(string: defaultMessagesURL) else {
                throw AynaError.invalidEndpoint(defaultMessagesURL)
            }
            return url
        }

        let trimmed = customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = URL(string: trimmed) else {
            throw AynaError.invalidEndpoint(trimmed)
        }

        guard let scheme = url.scheme?.lowercased() else {
            throw AynaError.invalidEndpoint(trimmed)
        }

        let isLoopbackHTTP = scheme == "http" && Self.isLoopbackHost(url.host)

        if scheme == "http", !isLoopbackHTTP {
            throw AynaError.invalidEndpoint("HTTP endpoints are not allowed (use HTTPS): \(trimmed)")
        }

        if scheme != "http", scheme != "https" {
            throw AynaError.invalidEndpoint("Invalid URL scheme: \(scheme)")
        }

        let finalURL = appendMessagesPathIfNeeded(trimmed)

        guard let result = URL(string: finalURL) else {
            throw AynaError.invalidEndpoint(finalURL)
        }

        return result
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func sanitizedBaseEndpoint(_ endpoint: String) -> String {
        endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func appendMessagesPathIfNeeded(_ endpoint: String) -> String {
        let cleanBase = sanitizedBaseEndpoint(endpoint)
        let messagesPath = "/v1/messages"

        if cleanBase.hasSuffix("/messages") || cleanBase.hasSuffix("/v1/messages") {
            return cleanBase
        }

        if cleanBase.hasSuffix("/v1") {
            return cleanBase + "/messages"
        }

        if cleanBase.contains("/v1/") {
            return cleanBase
        }

        return "\(cleanBase)\(messagesPath)"
    }
}
