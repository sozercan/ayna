//
//  DuckDuckGoSearchService.swift
//  Ayna
//
//  API-key-free web search using DuckDuckGo's HTML endpoint.
//  Ported from Orka's internal/tools/web_search.go.
//

import Foundation
import os.log

/// Errors from DuckDuckGo search operations
enum DuckDuckGoSearchError: LocalizedError, Sendable {
    case networkError(Error)
    case parsingError
    case noResults
    case circuitOpen(retryAfterSeconds: Int)

    var errorDescription: String? {
        switch self {
        case let .networkError(error):
            "DuckDuckGo network error: \(error.localizedDescription)"
        case .parsingError:
            "Failed to parse DuckDuckGo results"
        case .noResults:
            "No results found"
        case let .circuitOpen(seconds):
            seconds > 0
                ? "DuckDuckGo search temporarily unavailable. Please try again in \(seconds)s."
                : "DuckDuckGo search temporarily unavailable. Please try again shortly."
        }
    }
}

/// API-key-free web search using DuckDuckGo's lightweight HTML endpoint.
///
/// Scrapes `https://html.duckduckgo.com/html/?q=<query>` and extracts
/// result links, titles, and snippets using Swift Regex.
@MainActor
final class DuckDuckGoSearchService {
    static let shared = DuckDuckGoSearchService()

    // MARK: - Constants

    private enum Constants {
        static let searchEndpoint = "https://html.duckduckgo.com/html/"
        static let maxResponseBytes = 1 << 20 // 1 MB
        static let timeoutSeconds: TimeInterval = 30
        static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        static let referer = "https://duckduckgo.com/"
        static let circuitLabel = "duckduckgo.search"
    }

    // MARK: - Private Properties

    private let urlSession: URLSession

    // MARK: - Initialization

    init(urlSession: URLSession? = nil) {
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = Constants.timeoutSeconds
            config.timeoutIntervalForResource = Constants.timeoutSeconds
            self.urlSession = URLSession(configuration: config)
        }
    }

    // MARK: - Public Methods

    /// Performs a web search using DuckDuckGo's HTML endpoint.
    /// No API key required.
    func search(query: String, maxResults: Int = 5) async throws -> WebSearchResponse {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard let url = URL(string: Constants.searchEndpoint) else {
            throw DuckDuckGoSearchError.parsingError
        }

        let circuitKey = NetworkCircuitBreaker.key(for: url, label: Constants.circuitLabel)
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            throw DuckDuckGoSearchError.circuitOpen(retryAfterSeconds: seconds)
        }

        log(.info, "🔍 Performing DuckDuckGo search", metadata: ["query": query])

        // POST with form-encoded body avoids DDG's CAPTCHA on GET requests
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Constants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Constants.referer, forHTTPHeaderField: "Referer")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html", forHTTPHeaderField: "Accept")

        var formComponents = URLComponents()
        formComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "b", value: ""),
            URLQueryItem(name: "kl", value: ""),
        ]
        request.httpBody = formComponents.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw DuckDuckGoSearchError.networkError(
                    URLError(.badServerResponse)
                )
            }

            guard httpResponse.statusCode == 200 else {
                if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }
                throw DuckDuckGoSearchError.networkError(
                    URLError(.badServerResponse)
                )
            }

            NetworkCircuitBreaker.recordSuccess(key: circuitKey)

            // Cap response at 1 MB
            let cappedData = data.prefix(Constants.maxResponseBytes)
            guard let html = String(data: cappedData, encoding: .utf8) else {
                throw DuckDuckGoSearchError.parsingError
            }

            let results = parseDDGResults(html: html, maxResults: maxResults)

            guard !results.isEmpty else {
                throw DuckDuckGoSearchError.noResults
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            log(.info, "✅ DuckDuckGo search completed", metadata: [
                "results": "\(results.count)",
                "responseTime": String(format: "%.2fs", elapsed),
            ])

            return WebSearchResponse(
                query: query,
                answer: nil,
                results: results,
                responseTime: elapsed,
                provider: .duckDuckGo
            )
        } catch let error as DuckDuckGoSearchError {
            throw error
        } catch {
            log(.error, "❌ DuckDuckGo search failed", metadata: [
                "error": error.localizedDescription,
            ])
            if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                NetworkCircuitBreaker.recordFailure(key: circuitKey)
            }
            throw DuckDuckGoSearchError.networkError(error)
        }
    }

    // MARK: - HTML Parsing

    /// Parses DuckDuckGo HTML search results into structured results.
    ///
    /// Extracts data using regex patterns matching DDG's HTML structure:
    /// - `result__a` class → link href + title
    /// - `result__snippet` class → snippet text
    /// - `uddg=` param → decode DDG's redirect URLs
    func parseDDGResults(html: String, maxResults: Int) -> [WebSearchResult] {
        // [\s\S]*? matches across newlines (.*? does not in Swift Regex)
        let linkRegex = /<a[^>]+class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/
        let snippetRegex = /<a[^>]+class="result__snippet"[^>]*>([\s\S]*?)<\/a>/

        let linkMatches = html.matches(of: linkRegex)
        var results: [WebSearchResult] = []

        for (i, linkMatch) in linkMatches.prefix(maxResults).enumerated() {
            let rawURL = String(linkMatch.output.1)
            let rawTitle = String(linkMatch.output.2)

            let decodedURL = decodeDDGURL(rawURL)
            guard !decodedURL.isEmpty else { continue }

            let title = stripHTMLTags(rawTitle)
            guard !title.isEmpty else { continue }

            // Find snippet between this link and the next link (or end of HTML)
            let searchStart = linkMatch.range.upperBound
            let searchEnd = (i + 1 < linkMatches.count) ? linkMatches[i + 1].range.lowerBound : html.endIndex
            let searchRange = searchStart ..< searchEnd
            let searchSlice = html[searchRange]

            let snippet: String = if let snippetMatch = searchSlice.firstMatch(of: snippetRegex) {
                stripHTMLTags(String(snippetMatch.output.1))
            } else {
                ""
            }

            let favicon: String? = if let parsedURL = URL(string: decodedURL), let host = parsedURL.host {
                "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
            } else {
                nil
            }

            results.append(WebSearchResult(
                title: title,
                url: decodedURL,
                content: snippet,
                favicon: favicon
            ))
        }

        return results
    }

    // MARK: - URL Decoding

    /// Extracts the real URL from DuckDuckGo's `uddg=` redirect parameter.
    ///
    /// DDG wraps result URLs in redirects like:
    /// `//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&rut=...`
    /// This function extracts and URL-decodes the actual target URL.
    func decodeDDGURL(_ rawURL: String) -> String {
        let uddgRegex = /uddg=([^&]+)/
        if let match = rawURL.firstMatch(of: uddgRegex) {
            let encoded = String(match.output.1)
            if let decoded = encoded.removingPercentEncoding {
                return decoded
            }
            return rawURL
        }

        // Not a redirect URL, return as-is if it looks like a URL
        if rawURL.hasPrefix("http") {
            return rawURL
        }
        return ""
    }

    // MARK: - HTML Stripping

    /// Strips HTML tags and decodes common HTML entities.
    func stripHTMLTags(_ string: String) -> String {
        let tagRegex = /<[^>]+>/
        var result = string.replacing(tagRegex, with: "")

        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Logging

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: message, metadata: metadata)
    }
}
