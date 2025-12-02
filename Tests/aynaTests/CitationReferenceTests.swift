@testable import Ayna
import XCTest

final class CitationReferenceTests: XCTestCase {
    // MARK: - Initialization Tests

    func testInitWithAllProperties() {
        let citation = CitationReference(
            number: 1,
            title: "Test Title",
            url: "https://example.com",
            favicon: "https://example.com/favicon.ico"
        )

        XCTAssertEqual(citation.number, 1)
        XCTAssertEqual(citation.title, "Test Title")
        XCTAssertEqual(citation.url, "https://example.com")
        XCTAssertEqual(citation.favicon, "https://example.com/favicon.ico")
    }

    func testInitWithoutFavicon() {
        let citation = CitationReference(
            number: 2,
            title: "No Favicon",
            url: "https://example.org"
        )

        XCTAssertEqual(citation.number, 2)
        XCTAssertEqual(citation.title, "No Favicon")
        XCTAssertEqual(citation.url, "https://example.org")
        XCTAssertNil(citation.favicon)
    }

    // MARK: - Codable Tests

    func testEncodeDecode() throws {
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

        XCTAssertEqual(decoded.number, original.number)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.url, original.url)
        XCTAssertEqual(decoded.favicon, original.favicon)
    }

    func testDecodeWithNullFavicon() throws {
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

        XCTAssertNil(citation.favicon)
    }

    func testDecodeWithMissingFavicon() throws {
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

        XCTAssertNil(citation.favicon)
    }

    // MARK: - Equatable Tests

    func testEquality() {
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

        XCTAssertEqual(citation1, citation2)
    }

    func testInequalityDifferentNumber() {
        let citation1 = CitationReference(number: 1, title: "Test", url: "https://test.com")
        let citation2 = CitationReference(number: 2, title: "Test", url: "https://test.com")

        XCTAssertNotEqual(citation1, citation2)
    }

    func testInequalityDifferentTitle() {
        let citation1 = CitationReference(number: 1, title: "Title A", url: "https://test.com")
        let citation2 = CitationReference(number: 1, title: "Title B", url: "https://test.com")

        XCTAssertNotEqual(citation1, citation2)
    }

    func testInequalityDifferentFavicon() {
        let citation1 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: "https://a.com/icon.ico")
        let citation2 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: "https://b.com/icon.ico")

        XCTAssertNotEqual(citation1, citation2)
    }

    func testInequalityNilVsNonNilFavicon() {
        let citation1 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: nil)
        let citation2 = CitationReference(number: 1, title: "Test", url: "https://test.com", favicon: "https://test.com/icon.ico")

        XCTAssertNotEqual(citation1, citation2)
    }

    // MARK: - Message Integration Tests

    func testMessageWithCitations() {
        let citations = [
            CitationReference(number: 1, title: "Source 1", url: "https://source1.com"),
            CitationReference(number: 2, title: "Source 2", url: "https://source2.com")
        ]

        let message = Message(
            role: .assistant,
            content: "This is a response with citations.",
            citations: citations
        )

        XCTAssertEqual(message.citations?.count, 2)
        XCTAssertEqual(message.citations?[0].title, "Source 1")
        XCTAssertEqual(message.citations?[1].title, "Source 2")
    }

    func testMessageWithoutCitations() {
        let message = Message(
            role: .assistant,
            content: "This is a response without citations."
        )

        XCTAssertNil(message.citations)
    }

    func testMessageCitationsEncodeDecode() throws {
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

        XCTAssertEqual(decoded.citations?.count, 1)
        XCTAssertEqual(decoded.citations?[0].number, 1)
        XCTAssertEqual(decoded.citations?[0].title, "Test Source")
        XCTAssertEqual(decoded.citations?[0].url, "https://test.com")
        XCTAssertEqual(decoded.citations?[0].favicon, "https://test.com/icon.ico")
    }

    func testMessageWithNilCitationsDecodesFromLegacyJSON() throws {
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

        XCTAssertNil(message.citations)
        XCTAssertEqual(message.content, "Legacy message")
    }
}
