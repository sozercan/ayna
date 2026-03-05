//
//  WebSearchCoordinator.swift
//  Ayna
//
//  Coordinates web search across providers (Tavily, DuckDuckGo).
//  Routes to Tavily when configured, falls back to DuckDuckGo (no API key needed).
//

import Foundation
import os.log

/// Coordinates web search across providers.
///
/// - If Tavily is configured and enabled, uses Tavily (higher quality, AI answers).
/// - Otherwise, uses DuckDuckGo (free, no API key required).
/// - If the active provider fails, silently falls back to the other provider.
@MainActor
final class WebSearchCoordinator: ObservableObject {
    static let shared = WebSearchCoordinator()

    // MARK: - Constants

    private enum Constants {
        static let toolName = "web_search"
    }

    // MARK: - Dependencies

    private let tavilyService: TavilyService
    private let ddgService: DuckDuckGoSearchService

    // MARK: - Computed Properties

    /// Web search is always available (DuckDuckGo requires no API key)
    var isAvailable: Bool {
        isEnabled
    }

    /// Whether web search is enabled by the user
    var isEnabled: Bool {
        tavilyService.isEnabled
    }

    /// Which provider will be used for the next search
    var activeProvider: WebSearchProvider {
        tavilyService.isConfigured ? .tavily : .duckDuckGo
    }

    /// Whether Tavily is configured (for UI display)
    var isTavilyConfigured: Bool {
        tavilyService.isConfigured
    }

    // MARK: - Initialization

    init(
        tavilyService: TavilyService? = nil,
        ddgService: DuckDuckGoSearchService? = nil
    ) {
        self.tavilyService = tavilyService ?? .shared
        self.ddgService = ddgService ?? .shared
    }

    // MARK: - Tool Definition

    /// Returns the OpenAI function tool definition for web search.
    /// The definition is the same regardless of which provider is active.
    func toolDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": Constants.toolName,
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
                            "description": "Results to return (1-5). Default 3.",
                            "minimum": 1,
                            "maximum": 5,
                        ],
                    ] as [String: Any],
                    "required": ["query"],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// The tool name used in function calling
    static var toolName: String {
        Constants.toolName
    }

    // MARK: - Execution

    /// Executes a web search tool call and returns formatted results
    func executeToolCall(arguments: [String: Any]) async -> String {
        let (result, _) = await executeToolCallWithCitations(arguments: arguments)
        return result
    }

    /// Executes a web search tool call and returns both formatted results and citations
    func executeToolCallWithCitations(arguments: [String: Any]) async -> (String, [CitationReference]) {
        guard let query = arguments["query"] as? String else {
            return ("Error: Missing 'query' parameter for web search", [])
        }

        let maxResults = min(max((arguments["max_results"] as? Int) ?? 3, 1), 5)
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

        // Try primary provider, then fallback
        let response: WebSearchResponse
        if tavilyService.isConfigured {
            response = await searchWithTavilyFallbackToDDG(
                query: query,
                topic: topic,
                searchDepth: searchDepth,
                maxResults: maxResults
            )
        } else {
            response = await searchWithDDGFallbackToError(
                query: query,
                maxResults: maxResults
            )
        }

        let formattedResult = response.formattedForModel(maxResults: maxResults)
        let citations = response.toCitationReferences(maxResults: maxResults)
        return (formattedResult, citations)
    }

    // MARK: - Private Search Methods

    /// Tries Tavily first, silently falls back to DuckDuckGo on failure
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
            log(.default, "⚠️ Tavily search failed, falling back to DuckDuckGo", metadata: [
                "error": error.localizedDescription,
            ])
            return await searchWithDDGFallbackToError(query: query, maxResults: maxResults)
        }
    }

    /// Tries DuckDuckGo, returns error response on failure
    private func searchWithDDGFallbackToError(
        query: String,
        maxResults: Int
    ) async -> WebSearchResponse {
        do {
            return try await ddgService.search(query: query, maxResults: maxResults)
        } catch {
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

    // MARK: - Logging

    private func log(_ level: OSLogType, _ message: String, metadata: [String: String] = [:]) {
        DiagnosticsLogger.log(.aiService, level: level, message: message, metadata: metadata)
    }
}
