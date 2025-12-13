//
//  TavilyService.swift
//  Ayna
//
//  Service for Tavily Web Search API integration.
//  Provides web search capabilities that models can invoke via function calling.
//

import Combine
import Foundation
import os.log

/// Service for managing Tavily Web Search API integration
@MainActor
final class TavilyService: ObservableObject {
    static let shared = TavilyService()

    // MARK: - Constants

    private enum Constants {
        static let apiEndpoint = "https://api.tavily.com/search"
        static let keychainAPIKey = "tavily_api_key"
        static let defaultsEnabledKey = "tavily_web_search_enabled"
        static let toolName = "web_search"
    }

    // MARK: - Published Properties

    @Published var apiKey: String {
        didSet {
            saveAPIKey()
        }
    }

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Constants.defaultsEnabledKey)
        }
    }

    // MARK: - Computed Properties

    /// Whether the service is properly configured with an API key
    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether web search is available (configured and enabled)
    var isAvailable: Bool {
        isConfigured && isEnabled
    }

    // MARK: - Private Properties

    private let keychain: KeychainStoring
    private let urlSession: URLSession

    // MARK: - Initialization

    init(keychain: KeychainStoring? = nil, urlSession: URLSession = .shared) {
        let effectiveKeychain = keychain ?? KeychainStorage.shared
        self.keychain = effectiveKeychain
        self.urlSession = urlSession

        // Load saved API key
        apiKey = (try? effectiveKeychain.string(for: Constants.keychainAPIKey)) ?? ""

        // Load enabled state
        isEnabled = UserDefaults.standard.bool(forKey: Constants.defaultsEnabledKey)

        log(.info, "🔍 TavilyService initialized", metadata: [
            "configured": "\(isConfigured)",
            "enabled": "\(isEnabled)"
        ])
    }

    // MARK: - Public Methods

    /// Performs a web search using the Tavily API
    /// - Parameters:
    ///   - query: The search query
    ///   - topic: Topic category (general, news, finance)
    ///   - searchDepth: Search depth (basic or advanced)
    ///   - maxResults: Maximum number of results (1-20)
    ///   - includeAnswer: Whether to include AI-generated answer
    /// - Returns: The search response
    func search(
        query: String,
        topic: TavilyTopic = .general,
        searchDepth: TavilySearchDepth = .basic,
        maxResults: Int = 5,
        includeAnswer: Bool = true
    ) async throws -> TavilySearchResponse {
        guard isConfigured else {
            throw TavilyError.notConfigured
        }

        let url = URL(string: Constants.apiEndpoint)!
        let circuitKey = NetworkCircuitBreaker.key(for: url, label: "tavily.search")
        let circuitGate = NetworkCircuitBreaker.shouldAllowRequest(key: circuitKey)
        if !circuitGate.allowed {
            let seconds = Int(circuitGate.retryAfterSeconds ?? 0)
            let message = seconds > 0
                ? "Web search temporarily unavailable. Please try again in \(seconds)s."
                : "Web search temporarily unavailable. Please try again shortly."
            throw TavilyError.apiError(message)
        }

        log(.info, "🔍 Performing web search", metadata: ["query": query])

        let request = TavilySearchRequest(
            apiKey: apiKey,
            query: query,
            topic: topic,
            searchDepth: searchDepth,
            maxResults: min(max(maxResults, 1), 20),
            includeAnswer: includeAnswer,
            includeRawContent: false,
            includeImages: false
        )

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)

        do {
            let (data, response) = try await urlSession.data(for: urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TavilyError.invalidResponse
            }

            switch httpResponse.statusCode {
            case 200:
                NetworkCircuitBreaker.recordSuccess(key: circuitKey)
                let decoder = JSONDecoder()
                do {
                    let searchResponse = try decoder.decode(TavilySearchResponse.self, from: data)
                    log(.info, "✅ Web search completed", metadata: [
                        "results": "\(searchResponse.results.count)",
                        "responseTime": String(format: "%.2fs", searchResponse.responseTime)
                    ])
                    return searchResponse
                } catch {
                    // Log the raw response for debugging
                    let rawResponse = String(data: data, encoding: .utf8) ?? "<unable to decode>"
                    log(.error, "❌ Failed to decode Tavily response", metadata: [
                        "error": error.localizedDescription,
                        "rawResponse": String(rawResponse.prefix(500))
                    ])
                    throw TavilyError.apiError("Failed to decode response: \(error.localizedDescription)")
                }

            case 401:
                log(.error, "❌ Invalid Tavily API key")
                throw TavilyError.invalidAPIKey

            case 429:
                log(.default, "⚠️ Tavily rate limit exceeded")
                NetworkCircuitBreaker.recordFailure(key: circuitKey)
                throw TavilyError.rateLimitExceeded

            default:
                if NetworkCircuitBreaker.shouldRecordFailure(statusCode: httpResponse.statusCode) {
                    NetworkCircuitBreaker.recordFailure(key: circuitKey)
                }
                // Try to parse error message from response
                let rawResponse = String(data: data, encoding: .utf8) ?? "<unable to decode>"
                log(.error, "❌ Tavily API error", metadata: [
                    "statusCode": "\(httpResponse.statusCode)",
                    "response": String(rawResponse.prefix(500))
                ])
                if let errorBody = try? JSONDecoder().decode(TavilyAPIError.self, from: data) {
                    throw TavilyError.apiError(errorBody.errorMessage ?? "Unknown error")
                }
                throw TavilyError.apiError("HTTP \(httpResponse.statusCode)")
            }
        } catch let error as TavilyError {
            throw error
        } catch {
            log(.error, "❌ Network error during web search", metadata: ["error": error.localizedDescription])
            if NetworkCircuitBreaker.shouldRecordFailure(error: error) {
                NetworkCircuitBreaker.recordFailure(key: circuitKey)
            }
            throw TavilyError.networkError(error)
        }
    }

    /// Executes a web search tool call and returns formatted results for the model
    /// - Parameter arguments: Tool call arguments from the model
    /// - Returns: Formatted search results string
    func executeToolCall(arguments: [String: Any]) async -> String {
        let (result, _) = await executeToolCallWithCitations(arguments: arguments)
        return result
    }

    /// Executes a web search tool call and returns both formatted results and citations
    /// - Parameter arguments: Tool call arguments from the model
    /// - Returns: Tuple of (formatted search results string, citations for inline display)
    func executeToolCallWithCitations(arguments: [String: Any]) async -> (String, [CitationReference]) {
        guard let query = arguments["query"] as? String else {
            return ("Error: Missing 'query' parameter for web search", [])
        }

        let topic: TavilyTopic = if let topicString = arguments["topic"] as? String,
                                    let parsedTopic = TavilyTopic(rawValue: topicString)
        {
            parsedTopic
        } else {
            .general
        }

        let searchDepth: TavilySearchDepth = if let depthString = arguments["search_depth"] as? String,
                                                let parsedDepth = TavilySearchDepth(rawValue: depthString)
        {
            parsedDepth
        } else {
            .basic
        }

        let maxResults = (arguments["max_results"] as? Int) ?? 3

        do {
            let response = try await search(
                query: query,
                topic: topic,
                searchDepth: searchDepth,
                maxResults: maxResults,
                includeAnswer: true
            )
            let formattedResult = response.formattedForModel(maxResults: maxResults)
            let citations = response.toCitationReferences(maxResults: maxResults)
            return (formattedResult, citations)
        } catch {
            log(.error, "❌ Tool call failed", metadata: ["error": error.localizedDescription])
            return ("Error searching the web: \(error.localizedDescription)", [])
        }
    }

    /// Returns the OpenAI function tool definition for web search
    func toolDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": Constants.toolName,
                "description": "Search the web for current information. Use for recent events, prices, weather, or time-sensitive topics.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "The search query"
                        ],
                        "topic": [
                            "type": "string",
                            "enum": ["general", "news", "finance"],
                            "description": "Topic: news, finance, or general"
                        ],
                        "max_results": [
                            "type": "integer",
                            "description": "Results to return (1-5). Default 3.",
                            "minimum": 1,
                            "maximum": 5
                        ]
                    ] as [String: Any],
                    "required": ["query"]
                ] as [String: Any]
            ] as [String: Any]
        ]
    }

    /// The tool name used in function calling
    static var toolName: String {
        Constants.toolName
    }

    // MARK: - Private Methods

    private func saveAPIKey() {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            try? keychain.removeValue(for: Constants.keychainAPIKey)
        } else {
            try? keychain.setString(trimmedKey, for: Constants.keychainAPIKey)
        }
        log(.info, "💾 Tavily API key updated", metadata: ["configured": "\(isConfigured)"])
    }

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.openAIService, level: level, message: message, metadata: metadata)
    }
}

// MARK: - API Error Response

private struct TavilyAPIError: Codable {
    let detail: TavilyErrorDetail?
    let message: String?
    let error: String?

    struct TavilyErrorDetail: Codable {
        let error: String?
    }

    var errorMessage: String? {
        detail?.error ?? message ?? error
    }
}
