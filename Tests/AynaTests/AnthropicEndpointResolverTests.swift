//
//  AnthropicEndpointResolverTests.swift
//  aynaTests
//
//  Created on 1/30/26.
//

@testable import Ayna
import Foundation
import Testing

@Suite("AnthropicEndpointResolver Tests")
struct AnthropicEndpointResolverTests {
    // MARK: - Default Endpoint Tests

    @Test("Default endpoint returns correct URL")
    func defaultEndpointReturnsCorrectURL() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: nil)
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("Empty custom endpoint returns default URL")
    func emptyCustomEndpointReturnsDefaultURL() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "")
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("Whitespace-only custom endpoint returns default URL")
    func whitespaceOnlyCustomEndpointReturnsDefaultURL() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "   ")
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    // MARK: - Custom Endpoint Tests

    @Test("Custom endpoint appends /v1/messages path")
    func customEndpointAppendsPath() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com")
        #expect(url.absoluteString == "https://my-proxy.com/v1/messages")
    }

    @Test("Custom endpoint with trailing slash appends path correctly")
    func customEndpointWithTrailingSlashAppendsPath() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com/")
        #expect(url.absoluteString == "https://my-proxy.com/v1/messages")
    }

    @Test("Custom endpoint already containing /v1/messages preserves path")
    func customEndpointWithFullPathPreservesPath() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com/v1/messages")
        #expect(url.absoluteString == "https://my-proxy.com/v1/messages")
    }

    @Test("Custom endpoint containing /messages preserves path")
    func customEndpointWithMessagesPreservesPath() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com/api/messages")
        #expect(url.absoluteString == "https://my-proxy.com/api/messages")
    }

    @Test("Custom endpoint with port appends path")
    func customEndpointWithPortAppendsPath() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com:8080")
        #expect(url.absoluteString == "https://my-proxy.com:8080/v1/messages")
    }

    // MARK: - Localhost Development Tests

    @Test("HTTP localhost is allowed for development")
    func httpLocalhostAllowed() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "http://localhost:8080")
        #expect(url.absoluteString == "http://localhost:8080/v1/messages")
    }

    @Test("HTTP 127.0.0.1 is allowed for development")
    func http127IsAllowed() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "http://127.0.0.1:8080")
        #expect(url.absoluteString == "http://127.0.0.1:8080/v1/messages")
    }

    @Test("HTTPS localhost is allowed")
    func httpsLocalhostAllowed() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://localhost:8080")
        #expect(url.absoluteString == "https://localhost:8080/v1/messages")
    }

    // MARK: - Error Cases

    @Test("HTTP non-localhost throws error")
    func httpNonLocalhostThrowsError() throws {
        #expect(throws: AynaError.self) {
            _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: "http://insecure.com")
        }
    }

    @Test("Malformed URL throws error")
    func malformedURLThrowsError() throws {
        #expect(throws: AynaError.self) {
            _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: "not-a-url")
        }
    }

    @Test("URL with invalid scheme throws error")
    func invalidSchemeThrowsError() throws {
        #expect(throws: AynaError.self) {
            _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: "ftp://example.com")
        }
    }

    @Test("URL without scheme throws error")
    func missingSchemeThrowsError() throws {
        #expect(throws: AynaError.self) {
            _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: "example.com/api")
        }
    }
}
