import Foundation
import os.log

@MainActor
final class WebSearchCoordinator: ObservableObject {
    static let shared = WebSearchCoordinator()

    nonisolated static let toolName = "web_search"

    private let tavilyService: TavilyService
    private let ddgService: DuckDuckGoSearchService

    var isAvailable: Bool {
        isEnabled
    }

    var isEnabled: Bool {
        tavilyService.isEnabled
    }

    var activeProvider: WebSearchProvider {
        tavilyService.isConfigured ? .tavily : .duckDuckGo
    }

    var isTavilyConfigured: Bool {
        tavilyService.isConfigured
    }

    init(
        tavilyService: TavilyService? = nil,
        ddgService: DuckDuckGoSearchService? = nil
    ) {
        self.tavilyService = tavilyService ?? .shared
        self.ddgService = ddgService ?? .shared
    }

    func toolDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": Self.toolName,
                "description": "Search the web for information. Use this tool for any factual question, to look up people, organizations, recent events, current data, or when you're unsure about the answer.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "The search query",
                        ],
                        "topic": [
                            "type": "string",
                            "enum": ["general", "news", "finance"],
                            "description": "Topic: news, finance, or general",
                        ],
                        "max_results": [
                            "type": "integer",
                            "description": "Results to return (1-10). Default 5.",
                            "minimum": 1,
                            "maximum": 10,
                        ],
                    ] as [String: Any],
                    "required": ["query"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    func executeToolCall(arguments: [String: Any]) async -> String {
        let (result, _) = await executeToolCallWithCitations(arguments: arguments)
        return result
    }

    func executeToolCallWithCitations(arguments: [String: Any]) async -> (String, [CitationReference]) {
        guard let query = arguments["query"] as? String else {
            return ("Error: Missing 'query' parameter for web search", [])
        }

        let defaultMaxResults = tavilyService.isConfigured ? 3 : 5
        let maxResults = min(max((arguments["max_results"] as? Int) ?? defaultMaxResults, 1), 10)
        let topic: TavilyTopic = if let topicString = arguments["topic"] as? String,
                                    let parsed = TavilyTopic(rawValue: topicString)
        {
            parsed
        } else {
            .general
        }

        let searchDepth: TavilySearchDepth = if let depthString = arguments["search_depth"] as? String,
                                                let parsed = TavilySearchDepth(rawValue: depthString)
        {
            parsed
        } else {
            .basic
        }

        let response: WebSearchResponse = if tavilyService.isConfigured {
            await searchWithTavilyFallbackToDDG(
                query: query,
                topic: topic,
                searchDepth: searchDepth,
                maxResults: maxResults
            )
        } else {
            await searchWithDDGFallbackToError(
                query: query,
                maxResults: maxResults
            )
        }

        let formattedResult = response.formattedForModel(maxResults: maxResults)
        let citations = response.toCitationReferences(maxResults: maxResults)
        return (formattedResult, citations)
    }

    private func searchWithTavilyFallbackToDDG(
        query: String,
        topic: TavilyTopic,
        searchDepth: TavilySearchDepth,
        maxResults: Int
    ) async -> WebSearchResponse {
        do {
            let tavilyResponse = try await tavilyService.search(
                query: query,
                topic: topic,
                searchDepth: searchDepth,
                maxResults: maxResults,
                includeAnswer: true
            )
            return tavilyResponse.toWebSearchResponse()
        } catch {
            guard !Task.isCancelled else {
                return cancelledResponse(query: query, provider: .tavily)
            }
            log(.default, "⚠️ Tavily search failed, falling back to DuckDuckGo", metadata: [
                "error": error.localizedDescription,
            ])
            return await searchWithDDGFallbackToError(query: query, maxResults: maxResults)
        }
    }

    private func searchWithDDGFallbackToError(
        query: String,
        maxResults: Int
    ) async -> WebSearchResponse {
        do {
            return try await ddgService.search(query: query, maxResults: maxResults)
        } catch {
            guard !Task.isCancelled else {
                return cancelledResponse(query: query, provider: .duckDuckGo)
            }
            log(.error, "❌ All search providers failed", metadata: [
                "error": error.localizedDescription,
            ])
            return WebSearchResponse(
                query: query,
                answer: nil,
                results: [],
                responseTime: 0,
                provider: .duckDuckGo
            )
        }
    }

    private func cancelledResponse(query: String, provider: WebSearchProvider) -> WebSearchResponse {
        WebSearchResponse(
            query: query,
            answer: nil,
            results: [],
            responseTime: 0,
            provider: provider
        )
    }

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: message, metadata: metadata)
    }
}
