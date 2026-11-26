import Foundation
import os.log

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

@MainActor
final class DuckDuckGoSearchService {
    static let shared = DuckDuckGoSearchService()

    private enum Constants {
        static let searchEndpoint = "https://html.duckduckgo.com/html/"
        static let maxResponseBytes = 1 << 20
        static let timeoutSeconds: TimeInterval = 30
        static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        static let referer = "https://duckduckgo.com/"
        static let circuitLabel = "duckduckgo.search"
    }

    private static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = Constants.timeoutSeconds
        config.timeoutIntervalForResource = Constants.timeoutSeconds
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    private let urlSession: URLSession

    init(urlSession: URLSession? = nil) {
        self.urlSession = urlSession ?? Self.defaultSession
    }

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
            let (bytes, response) = try await urlSession.bytes(for: request)

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

            let data = try await DuckDuckGoResponseReader.read(
                bytes,
                maxBytes: Constants.maxResponseBytes
            )
            NetworkCircuitBreaker.recordSuccess(key: circuitKey)

            guard let html = String(data: data, encoding: .utf8) else {
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
            if Task.isCancelled {
                throw CancellationError()
            }
            log(.error, "❌ DuckDuckGo search failed", metadata: [
                "error": error.localizedDescription,
            ])
            if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                NetworkCircuitBreaker.recordFailure(key: circuitKey)
            }
            throw DuckDuckGoSearchError.networkError(error)
        }
    }

    func parseDDGResults(html: String, maxResults: Int) -> [WebSearchResult] {
        let linkRegex = /<a[^>]+class="result__a"[^>]*href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/
        let snippetRegex = /<a[^>]+class="result__snippet"[^>]*>([\s\S]*?)<\/a>/

        let linkMatches = html.matches(of: linkRegex)
        var results: [WebSearchResult] = []

        for (index, linkMatch) in linkMatches.prefix(maxResults).enumerated() {
            let rawURL = String(linkMatch.output.1)
            let rawTitle = String(linkMatch.output.2)

            let decodedURL = decodeDDGURL(rawURL)
            guard !decodedURL.isEmpty else { continue }

            let title = stripHTMLTags(rawTitle)
            guard !title.isEmpty else { continue }

            let searchStart = linkMatch.range.upperBound
            let searchEnd = (index + 1 < linkMatches.count) ? linkMatches[index + 1].range.lowerBound : html.endIndex
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

    func decodeDDGURL(_ rawURL: String) -> String {
        let uddgRegex = /uddg=([^&]+)/
        if let match = rawURL.firstMatch(of: uddgRegex) {
            let encoded = String(match.output.1)
            if let decoded = encoded.removingPercentEncoding {
                return decoded
            }
            return rawURL
        }

        if rawURL.hasPrefix("http") {
            return rawURL
        }
        return ""
    }

    func stripHTMLTags(_ string: String) -> String {
        WebTextExtractor.plainText(fromHTMLFragment: string)
    }

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: message, metadata: metadata)
    }
}

enum DuckDuckGoResponseReader {
    static func read<Bytes: AsyncSequence>(
        _ bytes: Bytes,
        maxBytes: Int
    ) async throws -> Data where Bytes.Element == UInt8 {
        guard maxBytes > 0 else { return Data() }

        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))

        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)

            if data.count >= maxBytes {
                break
            }
        }

        return data
    }
}
