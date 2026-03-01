//
//  WebFetchService.swift
//  Ayna
//
//  Cross-platform web fetch tool for fetching URL content.
//  Available on macOS, iOS, and watchOS.
//

#if !os(watchOS)
    import CFNetwork
#endif
import Foundation
import os.log

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

/// URLSession delegate that validates redirect targets against private IP ranges.
/// Prevents SSRF bypass via HTTP redirects (e.g., 302 to http://169.254.169.254/).
final class SSRFRedirectValidator: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              let host = url.host,
              (url.scheme == "https" || url.scheme == "http"),
              !Self.isPrivateHost(host)
        else {
            // Block redirect to private/internal address or non-HTTP scheme
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    /// Checks if a host is a private/internal address
    static func isPrivateHost(_ host: String) -> Bool {
        let lowercased = host.lowercased()

        // Localhost variants
        if lowercased == "localhost" || lowercased == "127.0.0.1" || lowercased == "::1" {
            return true
        }

        // Block 0.0.0.0 (binds to all interfaces)
        if lowercased == "0.0.0.0" {
            return true
        }

        // IPv6 private/local ranges
        if lowercased.hasPrefix("fd") || lowercased.hasPrefix("fe80:") || lowercased.hasPrefix("fc") {
            return true
        }

        // Check for IP addresses in private ranges
        let parts = lowercased.split(separator: ".")
        if parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) {
            // 127.x.x.x - Loopback
            if first == 127 { return true }
            // 10.x.x.x
            if first == 10 { return true }
            // 172.16.x.x - 172.31.x.x
            if first == 172, (16 ... 31).contains(second) { return true }
            // 192.168.x.x
            if first == 192, second == 168 { return true }
            // 169.254.x.x (link-local, includes cloud metadata 169.254.169.254)
            if first == 169, second == 254 { return true }
            // 0.x.x.x - "This" network
            if first == 0 { return true }
        }

        return false
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
    var isEnabled: Bool = true

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

        // Validate URL
        guard let parsedURL = URL(string: url),
              let host = parsedURL.host,
              parsedURL.scheme == "https" || parsedURL.scheme == "http"
        else {
            throw WebFetchError.invalidURL(url: url)
        }

        // SSRF protection: Block internal/private IPs
        // Also resolves DNS to prevent DNS rebinding attacks
        if await resolveAndCheckHost(host) {
            throw WebFetchError.ssrfBlocked(url: url)
        }

        // Fetch with timeout
        var request = URLRequest(url: parsedURL)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeoutSeconds)
        request.setValue("Ayna/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            let session = URLSession(configuration: .ephemeral, delegate: SSRFRedirectValidator(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            (data, response) = try await session.data(for: request)
        } catch {
            throw WebFetchError.networkError(underlying: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.networkError(underlying: "Invalid response")
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw WebFetchError.httpError(statusCode: httpResponse.statusCode)
        }

        // Check content size
        guard data.count <= maxResponseSize else {
            throw WebFetchError.responseToLarge(size: data.count, limit: maxResponseSize)
        }

        guard let content = String(data: data, encoding: .utf8) else {
            throw WebFetchError.binaryContent
        }

        // Convert HTML to plain text if content appears to be HTML
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        let result = if contentType.contains("text/html") || content.contains("<html") {
            htmlToPlainText(content)
        } else {
            content
        }

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

    // MARK: - Private Helpers

    /// Checks if an IP address string is in private/internal ranges
    private func isPrivateIPAddress(_ address: String) -> Bool {
        let lowercased = address.lowercased()

        // IPv6 private/local ranges
        if lowercased.hasPrefix("fd") { return true }
        if lowercased.hasPrefix("fe80:") { return true }
        if lowercased.hasPrefix("fc") { return true }
        if lowercased == "::1" { return true }

        // Check for IPv4 addresses in private ranges
        let parts = lowercased.split(separator: ".")
        if parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) {
            if first == 127 { return true }
            if first == 10 { return true }
            if first == 172, (16 ... 31).contains(second) { return true }
            if first == 192, second == 168 { return true }
            if first == 169, second == 254 { return true }
            if first == 0 { return true }
        }

        return false
    }

    /// Resolves a hostname to IP addresses and checks if any are private (DNS rebinding protection)
    private func resolveAndCheckHost(_ host: String) async -> Bool {
        // First check the hostname string itself
        if isPrivateHost(host) {
            return true
        }

        #if !os(watchOS)
            // Resolve DNS and check all returned IP addresses
            let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)

            CFHostStartInfoResolution(hostRef, .addresses, nil)
            guard let addresses = CFHostGetAddressing(hostRef, &resolved)?.takeUnretainedValue() as? [Data],
                  resolved.boolValue
            else {
                // If DNS resolution fails, allow the request to proceed
                // URLSession will handle the error appropriately
                return false
            }

            for addressData in addresses {
                let ipString = addressData.withUnsafeBytes { pointer -> String? in
                    guard let sockaddr = pointer.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                        return nil
                    }

                    if sockaddr.pointee.sa_family == UInt8(AF_INET) {
                        var addr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                        return String(cString: buffer)
                    } else if sockaddr.pointee.sa_family == UInt8(AF_INET6) {
                        var addr = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                        inet_ntop(AF_INET6, &addr.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                        return String(cString: buffer)
                    }
                    return nil
                }

                if let ip = ipString, isPrivateIPAddress(ip) {
                    log(.default, "DNS rebinding protection: \(host) resolved to private IP \(ip)")
                    return true
                }
            }
        #endif

        return false
    }

    /// Checks if a host is a private/internal address (SSRF protection)
    private func isPrivateHost(_ host: String) -> Bool {
        SSRFRedirectValidator.isPrivateHost(host)
    }

    /// Converts HTML to plain text by stripping tags
    private func htmlToPlainText(_ html: String) -> String {
        var text = html

        // Remove script and style content
        text = text.replacingOccurrences(
            of: "<script[^>]*>.*?</script>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "<style[^>]*>.*?</style>",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // Replace block elements with newlines
        text = text.replacingOccurrences(
            of: "<(br|p|div|h[1-6]|li|tr)[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )

        // Remove all remaining tags
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode HTML entities
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        text = text.replacingOccurrences(of: "&lt;", with: "<")
        text = text.replacingOccurrences(of: "&gt;", with: ">")
        text = text.replacingOccurrences(of: "&quot;", with: "\"")
        text = text.replacingOccurrences(of: "&#39;", with: "'")

        // Collapse multiple newlines
        text = text.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: "🌐 WebFetch: \(message)", metadata: metadata)
    }
}
