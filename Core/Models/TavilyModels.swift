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
}

// MARK: - Formatting Extension

extension TavilySearchResponse {
    /// Formats the search response as a concise markdown string for the model
    /// This reduces token usage while preserving useful information
    func formattedForModel(maxResults: Int = 3) -> String {
        var output = ""

        // Include the AI-generated answer if available - this is the most valuable part
        if let answer, !answer.isEmpty {
            output += "**Answer:** \(answer)\n\n"
        }

        // Include top search results with shorter snippets for speed
        let topResults = Array(results.prefix(maxResults))
        if !topResults.isEmpty {
            output += "**Sources:**\n"
            for (index, result) in topResults.enumerated() {
                // Shorter snippets reduce tokens sent to LLM
                let snippet = result.content.prefix(150)
                output += "\(index + 1). [\(result.title)](\(result.url)): \(snippet)...\n"
            }
        }

        if output.isEmpty {
            output = "No results found."
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts search results to CitationReference array for inline display
    /// - Parameter maxResults: Maximum number of citations to include (default 5)
    /// - Returns: Array of CitationReference with numbered citations
    func toCitationReferences(maxResults: Int = 5) -> [CitationReference] {
        let topResults = Array(results.prefix(maxResults))
        return topResults.enumerated().map { index, result in
            CitationReference(
                number: index + 1,
                title: result.title,
                url: result.url,
                favicon: result.favicon
            )
        }
    }
}
