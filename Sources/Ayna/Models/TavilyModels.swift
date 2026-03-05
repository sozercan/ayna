//
//  TavilyModels.swift
//  Ayna
//
//  Models for Tavily Web Search API integration.
//

import Foundation

// MARK: - Enums

/// Topic category for search queries
enum TavilyTopic: String, Codable, CaseIterable, Sendable {
    case general
    case news
    case finance
}

/// Search depth affects result quality and API credits used
enum TavilySearchDepth: String, Codable, CaseIterable, Sendable {
    case basic
    case advanced
}

// MARK: - Request

/// Request body for Tavily Search API
struct TavilySearchRequest: Codable, Sendable {
    let apiKey: String
    let query: String
    var topic: TavilyTopic?
    var searchDepth: TavilySearchDepth?
    var maxResults: Int?
    var includeAnswer: Bool?
    var includeRawContent: Bool?
    var includeImages: Bool?
    var timeRange: TavilyTimeRange?
    var includeDomains: [String]?
    var excludeDomains: [String]?

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case query, topic
        case searchDepth = "search_depth"
        case maxResults = "max_results"
        case includeAnswer = "include_answer"
        case includeRawContent = "include_raw_content"
        case includeImages = "include_images"
        case timeRange = "time_range"
        case includeDomains = "include_domains"
        case excludeDomains = "exclude_domains"
    }
}

/// Time range filter for search results
enum TavilyTimeRange: String, Codable, Sendable {
    case day
    case week
    case month
    case year
}

// MARK: - Response

/// Response from Tavily Search API
struct TavilySearchResponse: Codable, Sendable {
    let query: String
    let answer: String?
    let images: [TavilyImage]?
    let results: [TavilySearchResult]
    let responseTime: Double
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case query, answer, images, results
        case responseTime = "response_time"
        case requestId = "request_id"
    }
}

/// Individual search result from Tavily
struct TavilySearchResult: Codable, Sendable {
    let title: String
    let url: String
    let content: String
    let score: Double
    let rawContent: String?
    let favicon: String?

    enum CodingKeys: String, CodingKey {
        case title, url, content, score
        case rawContent = "raw_content"
        case favicon
    }
}

/// Image result from Tavily (when includeImages is true)
struct TavilyImage: Codable, Sendable {
    let url: String
    let description: String?
}

// MARK: - Error

/// Errors that can occur during Tavily API operations
enum TavilyError: LocalizedError, Sendable {
    case notConfigured
    case invalidAPIKey
    case rateLimitExceeded
    case networkError(Error)
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Tavily API key not configured"
        case .invalidAPIKey:
            "Invalid Tavily API key"
        case .rateLimitExceeded:
            "Tavily API rate limit exceeded"
        case let .networkError(error):
            "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            "Invalid response from Tavily API"
        case let .apiError(message):
            "Tavily API error: \(message)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            "Add your Tavily API key in Settings → Web Search"
        case .invalidAPIKey:
            "Check your Tavily API key in Settings → Web Search"
        case .rateLimitExceeded:
            "Wait a moment and try again"
        case .networkError:
            "Check your internet connection"
        case .invalidResponse, .apiError:
            "Try again or contact support if the issue persists"
        }
    }
}

// MARK: - Formatting Extension

extension TavilySearchResponse {
    /// Converts to the common WebSearchResponse type
    func toWebSearchResponse() -> WebSearchResponse {
        WebSearchResponse(
            query: query,
            answer: answer,
            results: results.map { result in
                WebSearchResult(
                    title: result.title,
                    url: result.url,
                    content: result.content,
                    favicon: result.favicon
                )
            },
            responseTime: responseTime,
            provider: .tavily
        )
    }

    /// Formats the search response as a concise markdown string for the model.
    /// Delegates to the common WebSearchResponse formatting.
    func formattedForModel(maxResults: Int = 3) -> String {
        toWebSearchResponse().formattedForModel(maxResults: maxResults)
    }

    /// Converts search results to CitationReference array for inline display.
    /// Delegates to the common WebSearchResponse formatting.
    func toCitationReferences(maxResults: Int = 5) -> [CitationReference] {
        toWebSearchResponse().toCitationReferences(maxResults: maxResults)
    }
}
