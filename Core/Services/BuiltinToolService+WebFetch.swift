//
//  BuiltinToolService+WebFetch.swift
//  Ayna
//
//  Web fetch functionality for builtin tool service.
//

import Foundation
import os.log

#if os(macOS)
    extension BuiltinToolService {
        // MARK: - Web Fetch

        /// Fetches content from a URL and returns it as text.
        ///
        /// - Parameters:
        ///   - url: The URL to fetch
        ///   - conversationId: The conversation requesting this operation
        /// - Returns: The page content as plain text
        func webFetch(url: String, conversationId _: UUID) async throws -> String {
            guard isEnabled else {
                throw ToolExecutionError.serviceDisabled
            }

            log(.info, "web_fetch requested", metadata: ["url": url])

            // Validate URL
            guard let parsedURL = URL(string: url),
                  let host = parsedURL.host,
                  parsedURL.scheme == "https" || parsedURL.scheme == "http"
            else {
                throw ToolExecutionError.invalidPath(path: url, reason: "Invalid URL format")
            }

            // SSRF protection: Block internal/private IPs
            // Also resolves DNS to prevent DNS rebinding attacks
            if await resolveAndCheckHost(host) {
                throw ToolExecutionError.invalidPath(path: url, reason: "Access to internal addresses is not allowed")
            }

            // Fetch with timeout
            var request = URLRequest(url: parsedURL)
            request.httpMethod = "GET"
            request.timeoutInterval = TimeInterval(commandTimeoutSeconds)
            request.setValue("Ayna/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ToolExecutionError.commandFailed(command: "web_fetch", exitCode: -1, stderr: "Invalid response")
            }

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw ToolExecutionError.commandFailed(
                    command: "web_fetch",
                    exitCode: Int32(httpResponse.statusCode),
                    stderr: "HTTP \(httpResponse.statusCode)"
                )
            }

            // Check content size (10 MB limit)
            guard data.count <= maxReadSize else {
                throw ToolExecutionError.resourceLimitExceeded(
                    resource: "response size",
                    limit: "\(maxReadSize / 1024 / 1024) MB"
                )
            }

            guard let content = String(data: data, encoding: .utf8) else {
                throw ToolExecutionError.binaryFileUnsupported(path: url)
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

        /// Checks if a host is a private/internal address (SSRF protection)
        func isPrivateHost(_ host: String) -> Bool {
            let lowercased = host.lowercased()

            // Localhost variants
            if lowercased == "localhost" || lowercased == "127.0.0.1" || lowercased == "::1" {
                return true
            }

            // Block 0.0.0.0 (binds to all interfaces)
            if lowercased == "0.0.0.0" {
                return true
            }

            // Check if it's an IP address in private ranges
            if isPrivateIPAddress(lowercased) {
                return true
            }

            return false
        }

        /// Checks if an IP address string is in private/internal ranges
        func isPrivateIPAddress(_ address: String) -> Bool {
            let lowercased = address.lowercased()

            // IPv6 private/local ranges
            // fd00::/8 - Unique local addresses
            if lowercased.hasPrefix("fd") {
                return true
            }
            // fe80::/10 - Link-local addresses
            if lowercased.hasPrefix("fe80:") {
                return true
            }
            // fc00::/7 - Unique local addresses (includes fd00::/8)
            if lowercased.hasPrefix("fc") {
                return true
            }
            // ::1 - IPv6 loopback
            if lowercased == "::1" {
                return true
            }

            // Check for IPv4 addresses in private ranges
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

        /// Resolves a hostname to IP addresses and checks if any are private (DNS rebinding protection)
        func resolveAndCheckHost(_ host: String) async -> Bool {
            // First check the hostname string itself
            if isPrivateHost(host) {
                return true
            }

            // Resolve DNS and check all returned IP addresses
            // This prevents DNS rebinding attacks where a hostname initially resolves
            // to a public IP but later resolves to a private IP
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
                        // IPv4
                        var addr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        inet_ntop(AF_INET, &addr.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                        return String(cString: buffer)
                    } else if sockaddr.pointee.sa_family == UInt8(AF_INET6) {
                        // IPv6
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

            return false
        }

        /// Converts HTML to plain text by stripping tags
        func htmlToPlainText(_ html: String) -> String {
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
    }
#endif
