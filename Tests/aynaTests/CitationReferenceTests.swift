import Foundation
import Testing

@testable import Ayna

@Suite("CitationReference Tests")
struct CitationReferenceTests {
    // MARK: - Initialization Tests

    @Test("Init with all properties")
    func initWithAllProperties() {
        let citation = CitationReference(
            number: 1,
            title: "Test Title",
            url: "https://example.com",
            favicon: "https://example.com/favicon.ico"
        )

        #expect(citation.number == 1)
        #expect(citation.title == "Test Title")
        #expect(citation.url == "https://example.com")
        #expect(citation.favicon == "https://example.com/favicon.ico")
    }

    @Test("Init without favicon")
    func initWithoutFavicon() {
        let citation = CitationReference(
            number: 2,
            title: "No Favicon",
            url: "https://example.org"
        )

        #expect(citation.number == 2)
        #expect(citation.title == "No Favicon")
        #expect(citation.url == "https://example.org")
        #expect(citation.favicon == nil)
    }

    // MARK: - Codable Tests

    @Test("Encode and decode round trip")
    func encodeDecode() throws {
        let original = CitationReference(
            number: 3,
            title: "Encoded Title",
            url: "https://test.com",
            favicon: "https://test.com/icon.png"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(CitationReference.self, from: data)

        #expect(decoded.number == original.number)
        #expect(decoded.title == original.title)
        #expect(decoded.url == original.url)
        #expect(decoded.favicon == original.favicon)
    }

    @Test("Decode with null favicon")
    func decodeWithNullFavicon() throws {
        let json = """
        {
            "number": 1,
            "title": "Test",
            "url": "https://example.com",
            "favicon": null
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        let citation = try decoder.decode(CitationReference.self, from: data)

        #expect(citation.favicon == nil)
    }

    @Test("Decode with missing favicon")
    func decodeWithMissingFavicon() throws {
        let json = """
        {
            "number": 1,
            "title": "Test",
            "url": "https://example.com"
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        let citation = try decoder.decode(CitationReference.self, from: data)

        #expect(citation.favicon == nil)
    }

    // MARK: - Equatable Tests

    @Test("Equality")
    func equality() {
        let citation1 = CitationReference(
            number: 1,
            title: "Same",
            url: "https://same.com",
            favicon: "https://same.com/icon.ico"
        )

        let citation2 = CitationReference(
            number: 1,
            title: "Same",
            url: "https://same.com",
            favicon: "https://same.com/icon.ico"
        )

        #expect(citation1 == citation2)
    }

    @Test("Inequality with different number")
    func inequalityDifferentNumber() {
        let citation1 = CitationReference(number: 1, title: "Test", url: "https://test.com")
        let citation2 = CitationReference(number: 2, title: "Test", url: "https://test.com")

        #expect(citation1 != citation2)
    }

    @Test("Inequality with different title")
    func inequalityDifferentTitle() {
        let citation1 = CitationReference(number: 1, title: "Title A", url: "https://test.com")
        let citation2 = CitationReference(number: 1, title: "Title B", url: "https://test.com")

        #expect(citation1 != citation2)
    }

    @Test("Inequality with different favicon")
    func inequalityDifferentFavicon() {
        let citation1 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: "https://a.com/icon.ico")
        let citation2 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: "https://b.com/icon.ico")

        #expect(citation1 != citation2)
    }

    @Test("Inequality with nil vs non-nil favicon")
    func inequalityNilVsNonNilFavicon() {
        let citation1 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: nil)
        let citation2 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: "https://test.com/icon.ico")

        #expect(citation1 != citation2)
    }

    // MARK: - Message Integration Tests

    @Test("Message with citations")
    func messageWithCitations() {
        let citations = [
            CitationReference(number: 1, title: "Source 1", url: "https://source1.com"),
            CitationReference(number: 2, title: "Source 2", url: "https://source2.com")
        ]

        let message = Message(
            role: .assistant,
            content: "This is a response with citations.",
            citations: citations
        )

        #expect(message.citations?.count == 2)
        #expect(message.citations?[0].title == "Source 1")
        #expect(message.citations?[1].title == "Source 2")
    }

    @Test("Message without citations")
    func messageWithoutCitations() {
        let message = Message(
            role: .assistant,
            content: "This is a response without citations."
        )

        #expect(message.citations == nil)
    }

    @Test("Message citations encode and decode")
    func messageCitationsEncodeDecode() throws {
        let citations = [
            CitationReference(number: 1, title: "Test Source", url: "https://test.com", favicon: "https://test.com/icon.ico")
        ]

        let original = Message(
            role: .assistant,
            content: "Content with citation",
            citations: citations
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)

        #expect(decoded.citations?.count == 1)
        #expect(decoded.citations?[0].number == 1)
        #expect(decoded.citations?[0].title == "Test Source")
        #expect(decoded.citations?[0].url == "https://test.com")
        #expect(decoded.citations?[0].favicon == "https://test.com/icon.ico")
    }

    @Test("Message with nil citations decodes from legacy JSON")
    func messageWithNilCitationsDecodesFromLegacyJSON() throws {
        // Simulate a legacy message JSON without the citations field
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "role": "assistant",
            "content": "Legacy message",
            "timestamp": 0,
            "isLiked": false
        }
        """
        let data = json.data(using: .utf8)!

        let decoder = JSONDecoder()
        let message = try decoder.decode(Message.self, from: data)

        #expect(message.citations == nil)
        #expect(message.content == "Legacy message")
    }
}
