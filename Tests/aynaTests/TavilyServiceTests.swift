@testable import Ayna
import XCTest

@MainActor
final class TavilyServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var keychain: InMemoryKeychainStorage!

  override func setUp() async throws {
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

    override func tearDown() async throws {
        AppPreferences.reset()
        defaults.removePersistentDomain(forName: "TavilyServiceTests")
        defaults = nil
        keychain = nil
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

    func testIsConfiguredReturnsFalseWhenAPIKeyEmpty() {
        let service = makeService(apiKey: "")
        XCTAssertFalse(service.isConfigured)
    }

    func testIsConfiguredReturnsFalseWhenAPIKeyWhitespaceOnly() {
        let service = makeService(apiKey: "   ")
        XCTAssertFalse(service.isConfigured)
    }

    func testIsConfiguredReturnsTrueWhenAPIKeySet() {
        let service = makeService(apiKey: "tvly-valid-key")
        XCTAssertTrue(service.isConfigured)
    }

    func testIsAvailableRequiresBothConfiguredAndEnabled() {
        let service = makeService(apiKey: "tvly-valid-key", enabled: false)
        XCTAssertTrue(service.isConfigured)
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isAvailable)

        service.isEnabled = true
        XCTAssertTrue(service.isAvailable)
    }

    // MARK: - Search Success Tests

    func testSearchSuccessDecodesResponse() async throws {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { request in
            // Verify request structure
            XCTAssertEqual(request.url?.absoluteString, "https://api.tavily.com/search")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

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

        XCTAssertEqual(result.query, "test query")
        XCTAssertEqual(result.answer, "This is the AI-generated answer.")
        XCTAssertEqual(result.results.count, 2)
        XCTAssertEqual(result.results[0].title, "Result 1")
        XCTAssertEqual(result.results[0].url, "https://example.com/1")
        XCTAssertEqual(result.results[0].score, 0.95)
        XCTAssertEqual(result.responseTime, 1.23)
    }

    func testSearchRequestIncludesCorrectParameters() async throws {
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

        XCTAssertNotNil(capturedBody)
        XCTAssertEqual(capturedBody?["api_key"] as? String, "tvly-my-api-key")
        XCTAssertEqual(capturedBody?["query"] as? String, "Swift programming")
        XCTAssertEqual(capturedBody?["topic"] as? String, "news")
        XCTAssertEqual(capturedBody?["search_depth"] as? String, "advanced")
        XCTAssertEqual(capturedBody?["max_results"] as? Int, 3)
        XCTAssertEqual(capturedBody?["include_answer"] as? Bool, true)
    }

    func testSearchClampsMaxResultsToValidRange() async throws {
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
        XCTAssertEqual(capturedMaxResults, 20)

        // Test lower bound clamping (0 -> 1)
        _ = try await service.search(query: "test", maxResults: 0)
        XCTAssertEqual(capturedMaxResults, 1)
    }

    // MARK: - Error Handling Tests

    func testSearchThrowsNotConfiguredWhenAPIKeyMissing() async {
        let service = makeService(apiKey: "")

        do {
            _ = try await service.search(query: "test")
            XCTFail("Expected TavilyError.notConfigured to be thrown")
        } catch let error as TavilyError {
            guard case .notConfigured = error else {
                XCTFail("Expected .notConfigured, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSearchThrowsInvalidAPIKeyOn401() async {
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

        do {
            _ = try await service.search(query: "test")
            XCTFail("Expected TavilyError.invalidAPIKey to be thrown")
        } catch let error as TavilyError {
            guard case .invalidAPIKey = error else {
                XCTFail("Expected .invalidAPIKey, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSearchThrowsRateLimitExceededOn429() async {
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

        do {
            _ = try await service.search(query: "test")
            XCTFail("Expected TavilyError.rateLimitExceeded to be thrown")
        } catch let error as TavilyError {
            guard case .rateLimitExceeded = error else {
                XCTFail("Expected .rateLimitExceeded, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSearchParsesAPIErrorFromResponseBody() async {
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
            XCTFail("Expected TavilyError.apiError to be thrown")
        } catch let error as TavilyError {
            guard case let .apiError(message) = error else {
                XCTFail("Expected .apiError, got \(error)")
                return
            }
            XCTAssertEqual(message, "Invalid query parameter")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testSearchThrowsNetworkErrorOnConnectionFailure() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        do {
            _ = try await service.search(query: "test")
            XCTFail("Expected TavilyError.networkError to be thrown")
        } catch let error as TavilyError {
            guard case .networkError = error else {
                XCTFail("Expected .networkError, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - Tool Call Execution Tests

    func testExecuteToolCallReturnsFormattedResults() async {
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

        XCTAssertTrue(result.contains("**Answer:**"))
        XCTAssertTrue(result.contains("The weather is sunny."))
        XCTAssertTrue(result.contains("**Sources:**"))
        XCTAssertTrue(result.contains("[Weather Report](https://weather.com)"))
    }

    func testExecuteToolCallHandlesMissingQueryParameter() async {
        let service = makeService()

        let result = await service.executeToolCall(arguments: [:])

        XCTAssertEqual(result, "Error: Missing 'query' parameter for web search")
    }

    func testExecuteToolCallParsesOptionalParameters() async {
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

        XCTAssertEqual(capturedBody?["topic"] as? String, "finance")
        XCTAssertEqual(capturedBody?["search_depth"] as? String, "advanced")
        XCTAssertEqual(capturedBody?["max_results"] as? Int, 5)
    }

    func testExecuteToolCallReturnsErrorStringOnFailure() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let result = await service.executeToolCall(arguments: ["query": "test"])

        XCTAssertTrue(result.hasPrefix("Error searching the web:"))
    }

    // MARK: - Tool Definition Tests

    func testToolDefinitionMatchesOpenAIFunctionSchema() {
        let service = makeService()
        let definition = service.toolDefinition()

        XCTAssertEqual(definition["type"] as? String, "function")

        guard let function = definition["function"] as? [String: Any] else {
            XCTFail("Missing function definition")
            return
        }

        XCTAssertEqual(function["name"] as? String, "web_search")
        XCTAssertNotNil(function["description"] as? String)

        guard let parameters = function["parameters"] as? [String: Any] else {
            XCTFail("Missing parameters definition")
            return
        }

        XCTAssertEqual(parameters["type"] as? String, "object")

        guard let properties = parameters["properties"] as? [String: Any] else {
            XCTFail("Missing properties definition")
            return
        }

        // Verify required properties
        XCTAssertNotNil(properties["query"])
        XCTAssertNotNil(properties["topic"])
        XCTAssertNotNil(properties["max_results"])

        // Verify required array
        guard let required = parameters["required"] as? [String] else {
            XCTFail("Missing required array")
            return
        }

        XCTAssertTrue(required.contains("query"))
    }

    func testToolNameConstant() {
        XCTAssertEqual(TavilyService.toolName, "web_search")
    }

    // MARK: - Response Formatting Tests

    func testFormattedForModelWithAnswerAndResults() {
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

        XCTAssertTrue(formatted.contains("**Answer:** This is the answer."))
        XCTAssertTrue(formatted.contains("**Sources:**"))
        XCTAssertTrue(formatted.contains("1. [First Result](https://example.com/1)"))
        XCTAssertTrue(formatted.contains("2. [Second Result](https://example.com/2)"))
    }

    func testFormattedForModelWithoutAnswer() {
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

        XCTAssertFalse(formatted.contains("**Answer:**"))
        XCTAssertTrue(formatted.contains("**Sources:**"))
    }

    func testFormattedForModelWithEmptyResults() {
        let response = TavilySearchResponse(
            query: "obscure query",
            answer: nil,
            images: nil,
            results: [],
            responseTime: 0.3,
            requestId: nil
        )

        let formatted = response.formattedForModel()

        XCTAssertEqual(formatted, "No results found.")
    }

    func testFormattedForModelRespectsMaxResultsLimit() {
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

        XCTAssertTrue(formatted.contains("1. [Result 1]"))
        XCTAssertTrue(formatted.contains("2. [Result 2]"))
        XCTAssertFalse(formatted.contains("3. [Result 3]"))
        XCTAssertFalse(formatted.contains("4. [Result 4]"))
    }

    func testFormattedForModelTruncatesLongContent() {
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
        XCTAssertTrue(formatted.contains("..."))
        // The full 300-char content should NOT appear
        XCTAssertFalse(formatted.contains(longContent))
    }

    // MARK: - Citation Reference Tests

    func testToCitationReferencesConvertsResults() {
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

        XCTAssertEqual(citations.count, 2)
        XCTAssertEqual(citations[0].number, 1)
        XCTAssertEqual(citations[0].title, "First Result")
        XCTAssertEqual(citations[0].url, "https://example.com/1")
        XCTAssertEqual(citations[0].favicon, "https://example.com/favicon.ico")
        XCTAssertEqual(citations[1].number, 2)
        XCTAssertEqual(citations[1].title, "Second Result")
        XCTAssertEqual(citations[1].url, "https://example.com/2")
        // When no favicon is provided, Google's favicon service URL is generated
        XCTAssertEqual(citations[1].favicon, "https://www.google.com/s2/favicons?domain=example.com&sz=64")
    }

    func testToCitationReferencesRespectsMaxResults() {
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

        XCTAssertEqual(citations.count, 3)
        XCTAssertEqual(citations[0].number, 1)
        XCTAssertEqual(citations[1].number, 2)
        XCTAssertEqual(citations[2].number, 3)
    }

    func testToCitationReferencesReturnsEmptyArrayForNoResults() {
        let response = TavilySearchResponse(
            query: "test",
            answer: nil,
            images: nil,
            results: [],
            responseTime: 0.5,
            requestId: nil
        )

        let citations = response.toCitationReferences()

        XCTAssertTrue(citations.isEmpty)
    }

    func testExecuteToolCallWithCitationsReturnsFormattedResultAndCitations() async {
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
        XCTAssertTrue(result.contains("**Answer:**"))
        XCTAssertTrue(result.contains("Swift is a programming language."))
        XCTAssertTrue(result.contains("**Sources:**"))

        // Verify citations
        XCTAssertEqual(citations.count, 2)
        XCTAssertEqual(citations[0].number, 1)
        XCTAssertEqual(citations[0].title, "Swift.org")
        XCTAssertEqual(citations[0].url, "https://swift.org")
        XCTAssertEqual(citations[0].favicon, "https://swift.org/favicon.ico")
        XCTAssertEqual(citations[1].number, 2)
        XCTAssertEqual(citations[1].title, "Apple Developer")
        // When no favicon is provided, Google's favicon service URL is generated
        XCTAssertEqual(citations[1].favicon, "https://www.google.com/s2/favicons?domain=developer.apple.com&sz=64")
    }

    func testExecuteToolCallWithCitationsReturnsEmptyCitationsOnMissingQuery() async {
        let service = makeService()

        let (result, citations) = await service.executeToolCallWithCitations(arguments: [:])

        XCTAssertEqual(result, "Error: Missing 'query' parameter for web search")
        XCTAssertTrue(citations.isEmpty)
    }

    func testExecuteToolCallWithCitationsReturnsEmptyCitationsOnError() async {
        let service = makeService()

        TavilyMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let (result, citations) = await service.executeToolCallWithCitations(arguments: ["query": "test"])

        XCTAssertTrue(result.hasPrefix("Error searching the web:"))
        XCTAssertTrue(citations.isEmpty)
    }

    // MARK: - API Key Persistence Tests

    func testAPIKeyIsSavedToKeychain() throws {
        let service = makeService(apiKey: "")

        service.apiKey = "tvly-new-key"

        let storedKey = try keychain.string(for: "tavily_api_key")
        XCTAssertEqual(storedKey, "tvly-new-key")
    }

    func testEmptyAPIKeyRemovesFromKeychain() throws {
        // First set a key
        try keychain.setString("tvly-existing-key", for: "tavily_api_key")

        let service = makeService(apiKey: "tvly-existing-key")
        service.apiKey = ""

        let storedKey = try keychain.string(for: "tavily_api_key")
        XCTAssertNil(storedKey)
    }
}

// MARK: - Mock URL Protocol for Tavily Tests

private final class TavilyMockURLProtocol: URLProtocol {
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
