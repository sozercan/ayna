import Foundation

enum WebSearchProvider: String, Codable, Sendable {
    case tavily
    case duckDuckGo
}

struct WebSearchResponse: Codable, Sendable {
    let query: String
    let answer: String?
    let results: [WebSearchResult]
    let responseTime: Double
    let provider: WebSearchProvider
}

struct WebSearchResult: Codable, Sendable {
    let title: String
    let url: String
    let content: String
    let favicon: String?
}

extension WebSearchResponse {
    func formattedForModel(maxResults: Int = 3) -> String {
        var output = ""

        if let answer, !answer.isEmpty {
            output += "**Answer:** \(answer)\n\n"
        }

        let topResults = Array(results.prefix(maxResults))
        if !topResults.isEmpty {
            output += "Use the following search results to write a comprehensive answer. Synthesize the information into a natural response. Do not list URLs or add reference numbers — sources are shown separately.\n\n"
            for result in topResults {
                output += "• \(result.title)\n"
                if !result.content.isEmpty {
                    output += "\(result.content)\n"
                }
                output += "\n"
            }
        }

        if output.isEmpty {
            output = "No results found."
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

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
