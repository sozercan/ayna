//
//  WebSearchCoordinatorTests.swift
//  AynaTests
//
//  Tests for WebSearchCoordinator routing, fallback, and response formatting.
//

import Foundation
import Testing

@testable import Ayna

@Suite("WebSearchCoordinator Tests", .tags(.async), .serialized)
@MainActor
struct WebSearchCoordinatorTests {

    // MARK: - Provider Routing Tests

    @Test("Routes to DuckDuckGo when Tavily not configured")
    func routesToDDGWhenTavilyNotConfigured() {
        let tavily = TavilyService(keychain: MockKeychainStorage())
        // Don't set an API key — Tavily is unconfigured
        tavily.isEnabled = true

        let coordinator = WebSearchCoordinator(tavilyService: tavily)
        #expect(coordinator.activeProvider == .duckDuckGo)
    }

    @Test("Routes to Tavily when API key is configured")
    func routesToTavilyWhenConfigured() {
        let tavily = TavilyService(keychain: MockKeychainStorage())
        tavily.apiKey = "tvly-test-key"
        tavily.isEnabled = true

        let coordinator = WebSearchCoordinator(tavilyService: tavily)
        #expect(coordinator.activeProvider == .tavily)
    }

    @Test("isAvailable reflects isEnabled state")
    func isAvailableReflectsEnabledState() {
        let tavily = TavilyService(keychain: MockKeychainStorage())
        tavily.isEnabled = false

        let coordinator = WebSearchCoordinator(tavilyService: tavily)
        #expect(!coordinator.isAvailable)

        tavily.isEnabled = true
        #expect(coordinator.isAvailable)
    }

    @Test("Tool definition has correct name and structure")
    func toolDefinitionHasCorrectStructure() {
        let tavily = TavilyService(keychain: MockKeychainStorage())
        let coordinator = WebSearchCoordinator(tavilyService: tavily)

        let definition = coordinator.toolDefinition()
        let function = definition["function"] as? [String: Any]

        #expect(definition["type"] as? String == "function")
        #expect(function?["name"] as? String == "web_search")
        #expect(function?["description"] != nil)

        let parameters = function?["parameters"] as? [String: Any]
        let properties = parameters?["properties"] as? [String: Any]
        #expect(properties?["query"] != nil)
        #expect(properties?["topic"] != nil)
        #expect(properties?["max_results"] != nil)

        let required = parameters?["required"] as? [String]
        #expect(required == ["query"])
    }

    // MARK: - Execution Tests

    @Test("executeToolCall returns error for missing query", .timeLimit(.minutes(1)))
    func executeToolCallReturnsMissingQueryError() async {
        let tavily = TavilyService(keychain: MockKeychainStorage())
        let coordinator = WebSearchCoordinator(tavilyService: tavily)

        let result = await coordinator.executeToolCall(arguments: [:])
        #expect(result.contains("Error"))
        #expect(result.contains("query"))
    }

    // MARK: - WebSearchResponse Formatting Tests

    @Test("formattedForModel includes answer and sources")
    func formattedForModelIncludesAnswerAndSources() {
        let response = WebSearchResponse(
            query: "test",
            answer: "The answer is 42",
            results: [
                WebSearchResult(title: "Source 1", url: "https://example.com", content: "Some content here", favicon: nil),
                WebSearchResult(title: "Source 2", url: "https://other.com", content: "Other content", favicon: nil),
            ],
            responseTime: 0.5,
            provider: .tavily
        )

        let formatted = response.formattedForModel(maxResults: 3)
        #expect(formatted.contains("The answer is 42"))
        #expect(formatted.contains("• Source 1"))
        #expect(!formatted.contains("https://example.com"))
        #expect(formatted.contains("• Source 2"))
    }

    @Test("formattedForModel returns 'No results found' for empty results")
    func formattedForModelHandlesEmptyResults() {
        let response = WebSearchResponse(
            query: "test",
            answer: nil,
            results: [],
            responseTime: 0.5,
            provider: .duckDuckGo
        )

        let formatted = response.formattedForModel()
        #expect(formatted == "No results found.")
    }

    @Test("formattedForModel respects maxResults")
    func formattedForModelRespectsMaxResults() {
        let response = WebSearchResponse(
            query: "test",
            answer: nil,
            results: [
                WebSearchResult(title: "Result 1", url: "https://a.com", content: "A", favicon: nil),
                WebSearchResult(title: "Result 2", url: "https://b.com", content: "B", favicon: nil),
                WebSearchResult(title: "Result 3", url: "https://c.com", content: "C", favicon: nil),
            ],
            responseTime: 0.5,
            provider: .duckDuckGo
        )

        let formatted = response.formattedForModel(maxResults: 1)
        #expect(formatted.contains("Result 1"))
        #expect(!formatted.contains("Result 2"))
        #expect(!formatted.contains("Result 3"))
    }

    // MARK: - Citation Tests

    @Test("toCitationReferences generates correct citations")
    func toCitationReferencesGeneratesCorrectCitations() {
        let response = WebSearchResponse(
            query: "test",
            answer: nil,
            results: [
                WebSearchResult(title: "Example Page", url: "https://example.com/page", content: "Content", favicon: "https://example.com/favicon.ico"),
                WebSearchResult(title: "Other Page", url: "https://other.com", content: "Other", favicon: nil),
            ],
            responseTime: 0.5,
            provider: .duckDuckGo
        )

        let citations = response.toCitationReferences(maxResults: 5)
        #expect(citations.count == 2)

        #expect(citations[0].number == 1)
        #expect(citations[0].title == "Example Page")
        #expect(citations[0].url == "https://example.com/page")
        #expect(citations[0].favicon == "https://example.com/favicon.ico")

        #expect(citations[1].number == 2)
        #expect(citations[1].title == "Other Page")
        #expect(citations[1].favicon?.contains("google.com/s2/favicons") == true)
    }

    @Test("toCitationReferences respects maxResults")
    func toCitationReferencesRespectsMaxResults() {
        let response = WebSearchResponse(
            query: "test",
            answer: nil,
            results: [
                WebSearchResult(title: "R1", url: "https://a.com", content: "A", favicon: nil),
                WebSearchResult(title: "R2", url: "https://b.com", content: "B", favicon: nil),
                WebSearchResult(title: "R3", url: "https://c.com", content: "C", favicon: nil),
            ],
            responseTime: 0.5,
            provider: .duckDuckGo
        )

        let citations = response.toCitationReferences(maxResults: 2)
        #expect(citations.count == 2)
    }
}

// MARK: - Mock Keychain

private final class MockKeychainStorage: KeychainStoring, @unchecked Sendable {
    private var store: [String: String] = [:]
    private var dataStore: [String: Data] = [:]

    func string(for key: String) throws -> String? {
        store[key]
    }

    func setString(_ value: String, for key: String) throws {
        store[key] = value
    }

    func data(for key: String) throws -> Data? {
        dataStore[key]
    }

    func setData(_ data: Data, for key: String) throws {
        dataStore[key] = data
    }

    func removeValue(for key: String) throws {
        store.removeValue(forKey: key)
        dataStore.removeValue(forKey: key)
    }
}
