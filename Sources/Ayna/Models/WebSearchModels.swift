//
//  WebSearchModels.swift
//  Ayna
//
//  Common models for web search results, shared across providers
//  (Tavily, DuckDuckGo, etc.).
//

import Foundation

// MARK: - Search Provider

/// Identifies which web search provider produced results
enum WebSearchProvider: String, Codable, Sendable {
    case tavily
    case duckDuckGo
}

// MARK: - Response

/// Unified web search response produced by all search providers
struct WebSearchResponse: Codable, Sendable {
    let query: String
    let answer: String?
    let results: [WebSearchResult]
    let responseTime: Double
    let provider: WebSearchProvider
}

// MARK: - Result

/// Individual web search result from any provider
struct WebSearchResult: Codable, Sendable {
    let title: String
    let url: String
    let content: String
    let favicon: String?
}

// MARK: - Formatting Extension

extension WebSearchResponse {
    /// Formats the search response as a concise markdown string for the model.
    /// Reduces token usage while preserving useful information.
    func formattedForModel(maxResults: Int = 3) -> String {
        var output = ""

        if let answer, !answer.isEmpty {
            output += "**Answer:** \(answer)\n\n"
        }

        let topResults = Array(results.prefix(maxResults))
        if !topResults.isEmpty {
            output += "**Sources:**\n"
            for (index, result) in topResults.enumerated() {
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
    func toCitationReferences(maxResults: Int = 5) -> [CitationReference] {
        let topResults = Array(results.prefix(maxResults))
        return topResults.enumerated().map { index, result in
            let faviconURL: String? = if let existingFavicon = result.favicon, !existingFavicon.isEmpty {
                existingFavicon
            } else if let url = URL(string: result.url), let host = url.host {
                "https://www.google.com/s2/favicons?domain=\(host)&sz=64"
            } else {
                nil
            }

            return CitationReference(
                number: index + 1,
                title: result.title,
                url: result.url,
                favicon: faviconURL
            )
        }
    }
}
