//
//  DuckDuckGoSearchServiceTests.swift
//  AynaTests
//
//  Tests for DuckDuckGo HTML search scraping, URL decoding, and HTML stripping.
//

import Foundation
import Testing

@testable import Ayna

@Suite("DuckDuckGoSearchService Tests", .tags(.networking, .async), .serialized)
@MainActor
struct DuckDuckGoSearchServiceTests {
    init() {
        DDGMockURLProtocol.reset()
    }

    private func makeService() -> DuckDuckGoSearchService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DDGMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return DuckDuckGoSearchService(urlSession: session)
    }

    // MARK: - Search Tests

    @Test("Search returns parsed results from DDG HTML", .timeLimit(.minutes(1)))
    func searchReturnsParsedResults() async throws {
        let service = makeService()

        DDGMockURLProtocol.requestHandler = { request in
            #expect(request.url?.host == "html.duckduckgo.com")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Mozilla") == true)
            #expect(request.value(forHTTPHeaderField: "Referer") == "https://duckduckgo.com/")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data(DDGHTMLFixtures.twoResults.utf8)
            return (response, body)
        }

        let result = try await service.search(query: "swift programming", maxResults: 5)

        #expect(result.query == "swift programming")
        #expect(result.provider == .duckDuckGo)
        #expect(result.answer == nil)
        #expect(result.results.count == 2)
        #expect(result.results[0].title == "Swift Programming Language")
        #expect(result.results[0].url == "https://swift.org")
        #expect(result.results[0].content.contains("Swift is a powerful"))
        #expect(result.results[0].favicon?.contains("google.com/s2/favicons") == true)
        #expect(result.results[1].title == "Swift Documentation")
        #expect(result.results[1].url == "https://docs.swift.org")
    }

    @Test("Search respects maxResults limit", .timeLimit(.minutes(1)))
    func searchRespectsMaxResults() async throws {
        let service = makeService()

        DDGMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(DDGHTMLFixtures.twoResults.utf8))
        }

        let result = try await service.search(query: "test", maxResults: 1)
        #expect(result.results.count == 1)
        #expect(result.results[0].title == "Swift Programming Language")
    }

    @Test("Search throws noResults for empty HTML", .timeLimit(.minutes(1)))
    func searchThrowsNoResultsForEmptyHTML() async throws {
        let service = makeService()

        DDGMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("<html><body>No results</body></html>".utf8))
        }

        await #expect(throws: DuckDuckGoSearchError.self) {
            try await service.search(query: "xyznoresults123")
        }
    }

    @Test("Search throws networkError on HTTP failure", .timeLimit(.minutes(1)))
    func searchThrowsNetworkErrorOnHTTPFailure() async throws {
        let service = makeService()

        DDGMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        await #expect(throws: DuckDuckGoSearchError.self) {
            try await service.search(query: "test")
        }
    }

    // MARK: - HTML Parsing Tests

    @Test("parseDDGResults extracts links and snippets")
    func parseDDGResultsExtractsLinksAndSnippets() {
        let service = makeService()
        let results = service.parseDDGResults(html: DDGHTMLFixtures.twoResults, maxResults: 10)

        #expect(results.count == 2)
        #expect(results[0].title == "Swift Programming Language")
        #expect(results[0].url == "https://swift.org")
        #expect(results[0].content == "Swift is a powerful and intuitive programming language.")
    }

    @Test("parseDDGResults handles malformed HTML gracefully")
    func parseDDGResultsHandlesMalformedHTML() {
        let service = makeService()
        let results = service.parseDDGResults(html: "<div>no results here</div>", maxResults: 5)
        #expect(results.isEmpty)
    }

    @Test("parseDDGResults skips entries with empty URLs")
    func parseDDGResultsSkipsEmptyURLs() {
        let service = makeService()
        let html = """
        <a class="result__a" href="">Empty Link</a>
        <a class="result__snippet">Some snippet</a>
        """
        let results = service.parseDDGResults(html: html, maxResults: 5)
        #expect(results.isEmpty)
    }

    // MARK: - decodeDDGURL Tests

    @Test("decodeDDGURL extracts URL from uddg parameter")
    func decodeDDGURLExtractsFromUddg() {
        let service = makeService()

        let rawURL = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org%2Fdocumentation&rut=abc123"
        let decoded = service.decodeDDGURL(rawURL)
        #expect(decoded == "https://swift.org/documentation")
    }

    @Test("decodeDDGURL returns direct HTTP URLs as-is")
    func decodeDDGURLReturnsDirectHTTPURLs() {
        let service = makeService()

        let directURL = "https://example.com/page"
        let decoded = service.decodeDDGURL(directURL)
        #expect(decoded == "https://example.com/page")
    }

    @Test("decodeDDGURL returns empty for non-HTTP non-redirect URLs")
    func decodeDDGURLReturnsEmptyForInvalidURLs() {
        let service = makeService()

        let invalid = "not-a-url"
        let decoded = service.decodeDDGURL(invalid)
        #expect(decoded.isEmpty)
    }

    @Test("decodeDDGURL handles encoded special characters")
    func decodeDDGURLHandlesEncodedSpecialChars() {
        let service = makeService()

        let rawURL = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fsearch%3Fq%3Dhello%20world"
        let decoded = service.decodeDDGURL(rawURL)
        #expect(decoded == "https://example.com/search?q=hello world")
    }

    // MARK: - stripHTMLTags Tests

    @Test("stripHTMLTags removes HTML tags")
    func stripHTMLTagsRemovesTags() {
        let service = makeService()

        let result = service.stripHTMLTags("<b>Hello</b> <em>world</em>")
        #expect(result == "Hello world")
    }

    @Test("stripHTMLTags decodes common HTML entities")
    func stripHTMLTagsDecodesEntities() {
        let service = makeService()

        let result = service.stripHTMLTags("Tom &amp; Jerry &lt;3 &gt; &quot;quotes&quot; &#39;apostrophe&#39;")
        #expect(result == "Tom & Jerry <3 > \"quotes\" 'apostrophe'")
    }

    @Test("stripHTMLTags decodes nbsp entity")
    func stripHTMLTagsDecodesNbsp() {
        let service = makeService()

        let result = service.stripHTMLTags("hello&nbsp;world")
        #expect(result == "hello world")
    }

    @Test("stripHTMLTags trims whitespace")
    func stripHTMLTagsTrimsWhitespace() {
        let service = makeService()

        let result = service.stripHTMLTags("  \n  hello  \n  ")
        #expect(result == "hello")
    }

    @Test("stripHTMLTags handles empty string")
    func stripHTMLTagsHandlesEmptyString() {
        let service = makeService()

        let result = service.stripHTMLTags("")
        #expect(result.isEmpty)
    }
}

// MARK: - HTML Fixtures

private enum DDGHTMLFixtures {
    static let twoResults = """
    <html>
    <body>
    <div class="results">
        <div class="result">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fswift.org&rut=abc">Swift Programming Language</a>
            <a class="result__snippet">Swift is a powerful and intuitive programming language.</a>
        </div>
        <div class="result">
            <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fdocs.swift.org&rut=def"><b>Swift</b> Documentation</a>
            <a class="result__snippet">Official <b>Swift</b> documentation and tutorials.</a>
        </div>
    </div>
    </body>
    </html>
    """
}

// MARK: - Mock URL Protocol

private final class DDGMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        requestHandler = nil
        lastRequest = nil
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = DDGMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "DDGMock", code: -1))
            return
        }

        do {
            let (response, data) = try handler(request)
            DDGMockURLProtocol.lastRequest = request
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
