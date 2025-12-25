@testable import Ayna
import Foundation
import Testing

@Suite("TavilyService Tests")
@MainActor
struct TavilyServiceTests {
    private var defaults: UserDefaults
    private var keychain: InMemoryKeychainStorage

    init() {
        guard let suite = UserDefaults(suiteName: "TavilyServiceTests") else {
            fatalError("Failed to create UserDefaults suite for TavilyServiceTests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "TavilyServiceTests")
        defaults.synchronize()
        AppPreferences.use(defaults)

        keychain = InMemoryKeychainStorage()
        TavilyMockURLProtocol.reset()
    }

    private func makeService(apiKey: String = "tvly-test-key", enabled: Bool = true) -> TavilyService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TavilyMockURLProtocol.self]
        let session = URLSession(configuration: config)

        let service = TavilyService(keychain: keychain, urlSession: session)
        service.apiKey = apiKey
        service.isEnabled = enabled
        return service
    }

    // MARK: - Configuration Tests

    @Test("isConfigured returns false when API key empty")
    func isConfiguredReturnsFalseWhenAPIKeyEmpty() {
        let service = makeService(apiKey: "")
        #expect(!service.isConfigured)
    }

    @Test("isConfigured returns false when API key whitespace only")
    func isConfiguredReturnsFalseWhenAPIKeyWhitespaceOnly() {
        let service = makeService(apiKey: "   ")
        #expect(!service.isConfigured)
    }

    @Test("isConfigured returns true when API key set")
    func isConfiguredReturnsTrueWhenAPIKeySet() {
        let service = makeService(apiKey: "tvly-valid-key")
        #expect(service.isConfigured)
    }

    @Test("isAvailable requires both configured and enabled")
    func isAvailableRequiresBothConfiguredAndEnabled() {
        let service = makeService(apiKey: "tvly-valid-key", enabled: false)
        #expect(service.isConfigured)
        #expect(!service.isEnabled)
        #expect(!service.isAvailable)

        service.isEnabled = true
        #expect(service.isAvailable)
    }

    // MARK: - Search Success Tests

    @Test("Search success decodes response")
    func searchSuccessDecodesResponse() async throws {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { request in
            // Verify request structure
            #expect(request.url?.absoluteString == "https://api.tavily.com/search")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data("""
            {
                "query": "test query",
                "answer": "This is the AI-generated answer.",
                "results": [
                    {
                        "title": "Result 1",
                        "url": "https://example.com/1",
                        "content": "Content for result 1",
                        "score": 0.95
                    },
                    {
                        "title": "Result 2",
                        "url": "https://example.com/2",
                        "content": "Content for result 2",
                        "score": 0.85
                    }
                ],
                "response_time": 1.23
            }
            """.utf8)
            return (response, body)
        }

        let result = try await service.search(query: "test query")

        #expect(result.query == "test query")
        #expect(result.answer == "This is the AI-generated answer.")
        #expect(result.results.count == 2)
        #expect(result.results[0].title == "Result 1")
        #expect(result.results[0].url == "https://example.com/1")
        #expect(result.results[0].score == 0.95)
        #expect(result.responseTime == 1.23)
    }

    @Test("Search request includes correct parameters")
    func searchRequestIncludesCorrectParameters() async throws {
        let service = makeService(apiKey: "tvly-my-api-key")

        var capturedBody: [String: Any]?

        TavilyMockURLProtocol.requestHandler = { request in
            // Try httpBody first, then httpBodyStream
            var bodyData = request.httpBody
            if bodyData == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 {
                        data.append(buffer, count: read)
                    } else {
                        break
                    }
                }
                stream.close()
                bodyData = data
            }

            if let bodyData {
                capturedBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data("""
            {"query": "test", "results": [], "response_time": 0.5}
            """.utf8)
            return (response, body)
        }

        _ = try await service.search(
            query: "Swift programming",
            topic: .news,
            searchDepth: .advanced,
            maxResults: 3,
            includeAnswer: true
        )

        #expect(capturedBody != nil)
        #expect(capturedBody?["api_key"] as? String == "tvly-my-api-key")
        #expect(capturedBody?["query"] as? String == "Swift programming")
        #expect(capturedBody?["topic"] as? String == "news")
        #expect(capturedBody?["search_depth"] as? String == "advanced")
        #expect(capturedBody?["max_results"] as? Int == 3)
        #expect(capturedBody?["include_answer"] as? Bool == true)
    }

    @Test("Search clamps max results to valid range")
    func searchClampsMaxResultsToValidRange() async throws {
        let service = makeService()

        var capturedMaxResults: Int?

        TavilyMockURLProtocol.requestHandler = { request in
            // Try httpBody first, then httpBodyStream
            var bodyData = request.httpBody
            if bodyData == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 {
                        data.append(buffer, count: read)
                    } else {
                        break
                    }
                }
                stream.close()
                bodyData = data
            }

            if let bodyData,
               let body = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            {
                capturedMaxResults = body["max_results"] as? Int
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data("""
            {"query": "test", "results": [], "response_time": 0.5}
            """.utf8)
            return (response, body)
        }

        // Test upper bound clamping (25 -> 20)
        _ = try await service.search(query: "test", maxResults: 25)
        #expect(capturedMaxResults == 20)

        // Test lower bound clamping (0 -> 1)
        _ = try await service.search(query: "test", maxResults: 0)
        #expect(capturedMaxResults == 1)
    }

    // MARK: - Error Handling Tests

    @Test("Search throws notConfigured when API key missing")
    func searchThrowsNotConfiguredWhenAPIKeyMissing() async {
        let service = makeService(apiKey: "")

        await #expect(throws: TavilyError.self) {
            _ = try await service.search(query: "test")
        }
    }

    @Test("Search throws invalidAPIKey on 401")
    func searchThrowsInvalidAPIKeyOn401() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        await #expect(throws: TavilyError.self) {
            _ = try await service.search(query: "test")
        }
    }

    @Test("Search throws rateLimitExceeded on 429")
    func searchThrowsRateLimitExceededOn429() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        await #expect(throws: TavilyError.self) {
            _ = try await service.search(query: "test")
        }
    }

    @Test("Search parses API error from response body")
    func searchParsesAPIErrorFromResponseBody() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data("""
            {"detail": {"error": "Invalid query parameter"}}
            """.utf8)
            return (response, body)
        }

        do {
            _ = try await service.search(query: "test")
            Issue.record("Expected TavilyError.apiError to be thrown")
        } catch let error as TavilyError {
            guard case let .apiError(message) = error else {
                Issue.record("Expected .apiError, got \(error)")
                return
            }
            #expect(message == "Invalid query parameter")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Search throws networkError on connection failure")
    func searchThrowsNetworkErrorOnConnectionFailure() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        await #expect(throws: TavilyError.self) {
            _ = try await service.search(query: "test")
        }
    }

    // MARK: - Tool Call Execution Tests

    @Test("Execute tool call returns formatted results")
    func executeToolCallReturnsFormattedResults() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.tavily.com/search")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data("""
            {
                "query": "weather",
                "answer": "The weather is sunny.",
                "results": [
                    {
                        "title": "Weather Report",
                        "url": "https://weather.com",
                        "content": "Today's forecast shows clear skies with temperatures around 72°F.",
                        "score": 0.9
                    }
                ],
                "response_time": 0.8
            }
            """.utf8)
            return (response, body)
        }

        let result = await service.executeToolCall(arguments: ["query": "weather"])

        #expect(result.contains("**Answer:**"))
        #expect(result.contains("The weather is sunny."))
        #expect(result.contains("**Sources:**"))
        #expect(result.contains("[Weather Report](https://weather.com)"))
    }

    @Test("Execute tool call handles missing query parameter")
    func executeToolCallHandlesMissingQueryParameter() async {
        let service = makeService()

        let result = await service.executeToolCall(arguments: [:])

        #expect(result == "Error: Missing 'query' parameter for web search")
    }

    @Test("Execute tool call parses optional parameters")
    func executeToolCallParsesOptionalParameters() async {
        let service = makeService()

        var capturedBody: [String: Any]?

        TavilyMockURLProtocol.requestHandler = { request in
            // Try httpBody first, then httpBodyStream
            var bodyData = request.httpBody
            if bodyData == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let bufferSize = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
                defer { buffer.deallocate() }
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: bufferSize)
                    if read > 0 {
                        data.append(buffer, count: read)
                    } else {
                        break
                    }
                }
                stream.close()
                bodyData = data
            }

            if let bodyData {
                capturedBody = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            }

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = Data("""
            {"query": "test", "results": [], "response_time": 0.5}
            """.utf8)
            return (response, body)
        }

        _ = await service.executeToolCall(arguments: [
            "query": "finance news",
            "topic": "finance",
            "search_depth": "advanced",
            "max_results": 5
        ])

        #expect(capturedBody?["topic"] as? String == "finance")
        #expect(capturedBody?["search_depth"] as? String == "advanced")
        #expect(capturedBody?["max_results"] as? Int == 5)
    }

    @Test("Execute tool call returns error string on failure")
    func executeToolCallReturnsErrorStringOnFailure() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let result = await service.executeToolCall(arguments: ["query": "test"])

        #expect(result.hasPrefix("Error searching the web:"))
    }

    // MARK: - Tool Definition Tests

    @Test("Tool definition matches OpenAI function schema")
    func toolDefinitionMatchesOpenAIFunctionSchema() {
        let service = makeService()
        let definition = service.toolDefinition()

        #expect(definition["type"] as? String == "function")

        guard let function = definition["function"] as? [String: Any] else {
            Issue.record("Missing function definition")
            return
        }

        #expect(function["name"] as? String == "web_search")
        #expect(function["description"] as? String != nil)

        guard let parameters = function["parameters"] as? [String: Any] else {
            Issue.record("Missing parameters definition")
            return
        }

        #expect(parameters["type"] as? String == "object")

        guard let properties = parameters["properties"] as? [String: Any] else {
            Issue.record("Missing properties definition")
            return
        }

        // Verify required properties
        #expect(properties["query"] != nil)
        #expect(properties["topic"] != nil)
        #expect(properties["max_results"] != nil)

        // Verify required array
        guard let required = parameters["required"] as? [String] else {
            Issue.record("Missing required array")
            return
        }

        #expect(required.contains("query"))
    }

    @Test("Tool name constant")
    func toolNameConstant() {
        #expect(TavilyService.toolName == "web_search")
    }

    // MARK: - Response Formatting Tests

    @Test("Formatted for model with answer and results")
    func formattedForModelWithAnswerAndResults() {
        let response = TavilySearchResponse(
            query: "test",
            answer: "This is the answer.",
            images: nil,
            results: [
                TavilySearchResult(
                    title: "First Result",
                    url: "https://example.com/1",
                    content: "This is the content of the first result which might be quite long and detailed.",
                    score: 0.95,
                    rawContent: nil,
                    favicon: nil
                ),
                TavilySearchResult(
                    title: "Second Result",
                    url: "https://example.com/2",
                    content: "Second result content.",
                    score: 0.85,
                    rawContent: nil,
                    favicon: nil
                )
            ],
            responseTime: 1.0,
            requestId: nil
        )

        let formatted = response.formattedForModel(maxResults: 2)

        #expect(formatted.contains("**Answer:** This is the answer."))
        #expect(formatted.contains("**Sources:**"))
        #expect(formatted.contains("1. [First Result](https://example.com/1)"))
        #expect(formatted.contains("2. [Second Result](https://example.com/2)"))
    }

    @Test("Formatted for model without answer")
    func formattedForModelWithoutAnswer() {
        let response = TavilySearchResponse(
            query: "test",
            answer: nil,
            images: nil,
            results: [
                TavilySearchResult(
                    title: "Only Result",
                    url: "https://example.com",
                    content: "Content here.",
                    score: 0.9,
                    rawContent: nil,
                    favicon: nil
                )
            ],
            responseTime: 0.5,
            requestId: nil
        )

        let formatted = response.formattedForModel()

        #expect(!formatted.contains("**Answer:**"))
        #expect(formatted.contains("**Sources:**"))
    }

    @Test("Formatted for model with empty results")
    func formattedForModelWithEmptyResults() {
        let response = TavilySearchResponse(
            query: "obscure query",
            answer: nil,
            images: nil,
            results: [],
            responseTime: 0.3,
            requestId: nil
        )

        let formatted = response.formattedForModel()

        #expect(formatted == "No results found.")
    }

    @Test("Formatted for model respects max results limit")
    func formattedForModelRespectsMaxResultsLimit() {
        let response = TavilySearchResponse(
            query: "test",
            answer: nil,
            images: nil,
            results: [
                TavilySearchResult(title: "Result 1", url: "https://1.com", content: "Content 1", score: 0.9, rawContent: nil, favicon: nil),
                TavilySearchResult(title: "Result 2", url: "https://2.com", content: "Content 2", score: 0.8, rawContent: nil, favicon: nil),
                TavilySearchResult(title: "Result 3", url: "https://3.com", content: "Content 3", score: 0.7, rawContent: nil, favicon: nil),
                TavilySearchResult(title: "Result 4", url: "https://4.com", content: "Content 4", score: 0.6, rawContent: nil, favicon: nil)
            ],
            responseTime: 1.0,
            requestId: nil
        )

        let formatted = response.formattedForModel(maxResults: 2)

        #expect(formatted.contains("1. [Result 1]"))
        #expect(formatted.contains("2. [Result 2]"))
        #expect(!formatted.contains("3. [Result 3]"))
        #expect(!formatted.contains("4. [Result 4]"))
    }

    @Test("Formatted for model truncates long content")
    func formattedForModelTruncatesLongContent() {
        let longContent = String(repeating: "x", count: 300)
        let response = TavilySearchResponse(
            query: "test",
            answer: nil,
            images: nil,
            results: [
                TavilySearchResult(
                    title: "Result",
                    url: "https://example.com",
                    content: longContent,
                    score: 0.9,
                    rawContent: nil,
                    favicon: nil
                )
            ],
            responseTime: 0.5,
            requestId: nil
        )

        let formatted = response.formattedForModel()

        // Content should be truncated to 150 chars + "..."
        #expect(formatted.contains("..."))
        // The full 300-char content should NOT appear
        #expect(!formatted.contains(longContent))
    }

    // MARK: - Citation Reference Tests

    @Test("toCitationReferences converts results")
    func toCitationReferencesConvertsResults() {
        let response = TavilySearchResponse(
            query: "test",
            answer: "Answer",
            images: nil,
            results: [
                TavilySearchResult(
                    title: "First Result",
                    url: "https://example.com/1",
                    content: "Content 1",
                    score: 0.95,
                    rawContent: nil,
                    favicon: "https://example.com/favicon.ico"
                ),
                TavilySearchResult(
                    title: "Second Result",
                    url: "https://example.com/2",
                    content: "Content 2",
                    score: 0.85,
                    rawContent: nil,
                    favicon: nil
                )
            ],
            responseTime: 1.0,
            requestId: nil
        )

        let citations = response.toCitationReferences()

        #expect(citations.count == 2)
        #expect(citations[0].number == 1)
        #expect(citations[0].title == "First Result")
        #expect(citations[0].url == "https://example.com/1")
        #expect(citations[0].favicon == "https://example.com/favicon.ico")
        #expect(citations[1].number == 2)
        #expect(citations[1].title == "Second Result")
        #expect(citations[1].url == "https://example.com/2")
        // When no favicon is provided, Google's favicon service URL is generated
        #expect(citations[1].favicon == "https://www.google.com/s2/favicons?domain=example.com&sz=64")
    }

    @Test("toCitationReferences respects max results")
    func toCitationReferencesRespectsMaxResults() {
        let response = TavilySearchResponse(
            query: "test",
            answer: nil,
            images: nil,
            results: [
                TavilySearchResult(title: "R1", url: "https://1.com", content: "C1", score: 0.9, rawContent: nil, favicon: nil),
                TavilySearchResult(title: "R2", url: "https://2.com", content: "C2", score: 0.8, rawContent: nil, favicon: nil),
                TavilySearchResult(title: "R3", url: "https://3.com", content: "C3", score: 0.7, rawContent: nil, favicon: nil),
                TavilySearchResult(title: "R4", url: "https://4.com", content: "C4", score: 0.6, rawContent: nil, favicon: nil),
                TavilySearchResult(title: "R5", url: "https://5.com", content: "C5", score: 0.5, rawContent: nil, favicon: nil)
            ],
            responseTime: 1.0,
            requestId: nil
        )

        let citations = response.toCitationReferences(maxResults: 3)

        #expect(citations.count == 3)
        #expect(citations[0].number == 1)
        #expect(citations[1].number == 2)
        #expect(citations[2].number == 3)
    }

    @Test("toCitationReferences returns empty array for no results")
    func toCitationReferencesReturnsEmptyArrayForNoResults() {
        let response = TavilySearchResponse(
            query: "test",
            answer: nil,
            images: nil,
            results: [],
            responseTime: 0.5,
            requestId: nil
        )

        let citations = response.toCitationReferences()

        #expect(citations.isEmpty)
    }

    @Test("Execute tool call with citations returns formatted result and citations")
    func executeToolCallWithCitationsReturnsFormattedResultAndCitations() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.tavily.com/search")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = Data("""
            {
                "query": "swift programming",
                "answer": "Swift is a programming language.",
                "results": [
                    {
                        "title": "Swift.org",
                        "url": "https://swift.org",
                        "content": "The Swift Programming Language",
                        "score": 0.95,
                        "favicon": "https://swift.org/favicon.ico"
                    },
                    {
                        "title": "Apple Developer",
                        "url": "https://developer.apple.com/swift",
                        "content": "Swift Documentation",
                        "score": 0.90,
                        "favicon": null
                    }
                ],
                "response_time": 0.8
            }
            """.utf8)
            return (response, body)
        }

        let (result, citations) = await service.executeToolCallWithCitations(arguments: ["query": "swift programming"])

        // Verify formatted result
        #expect(result.contains("**Answer:**"))
        #expect(result.contains("Swift is a programming language."))
        #expect(result.contains("**Sources:**"))

        // Verify citations
        #expect(citations.count == 2)
        #expect(citations[0].number == 1)
        #expect(citations[0].title == "Swift.org")
        #expect(citations[0].url == "https://swift.org")
        #expect(citations[0].favicon == "https://swift.org/favicon.ico")
        #expect(citations[1].number == 2)
        #expect(citations[1].title == "Apple Developer")
        // When no favicon is provided, Google's favicon service URL is generated
        #expect(citations[1].favicon == "https://www.google.com/s2/favicons?domain=developer.apple.com&sz=64")
    }

    @Test("Execute tool call with citations returns empty citations on missing query")
    func executeToolCallWithCitationsReturnsEmptyCitationsOnMissingQuery() async {
        let service = makeService()

        let (result, citations) = await service.executeToolCallWithCitations(arguments: [:])

        #expect(result == "Error: Missing 'query' parameter for web search")
        #expect(citations.isEmpty)
    }

    @Test("Execute tool call with citations returns empty citations on error")
    func executeToolCallWithCitationsReturnsEmptyCitationsOnError() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let (result, citations) = await service.executeToolCallWithCitations(arguments: ["query": "test"])

        #expect(result.hasPrefix("Error searching the web:"))
        #expect(citations.isEmpty)
    }

    // MARK: - API Key Persistence Tests

    @Test("API key is saved to keychain")
    func apiKeyIsSavedToKeychain() throws {
        let service = makeService(apiKey: "")

        service.apiKey = "tvly-new-key"

        let storedKey = try keychain.string(for: "tavily_api_key")
        #expect(storedKey == "tvly-new-key")
    }

    @Test("Empty API key removes from keychain")
    func emptyAPIKeyRemovesFromKeychain() throws {
        // First set a key
        try keychain.setString("tvly-existing-key", for: "tavily_api_key")

        let service = makeService(apiKey: "tvly-existing-key")
        service.apiKey = ""

        let storedKey = try keychain.string(for: "tavily_api_key")
        #expect(storedKey == nil)
    }
}

// MARK: - Mock URL Protocol for Tavily Tests

private final class TavilyMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func reset() {
        requestHandler = nil
        lastRequest = nil
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = TavilyMockURLProtocol.requestHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(
                    domain: "TavilyMockURLProtocol",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Handler not set"]
                )
            )
            return
        }

        do {
            let (response, data) = try handler(request)
            TavilyMockURLProtocol.lastRequest = request
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
