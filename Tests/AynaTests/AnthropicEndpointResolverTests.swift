//
//  AnthropicEndpointResolverTests.swift
//  aynaTests
//
//  Created on 1/30/26.
//

@testable import Ayna
import Foundation
import Testing

struct AnthropicEndpointResolverTests {
    // MARK: - Default Endpoint Tests

    @Test
    func `Default endpoint returns correct URL`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: nil)
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test
    func `Empty custom endpoint returns default URL`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "")
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test
    func `Whitespace-only custom endpoint returns default URL`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "   ")
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    // MARK: - Custom Endpoint Tests

    @Test
    func `Custom endpoint appends /v1/messages path`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com")
        #expect(url.absoluteString == "https://my-proxy.com/v1/messages")
    }

    @Test
    func `Custom endpoint with trailing slash appends path correctly`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com/")
        #expect(url.absoluteString == "https://my-proxy.com/v1/messages")
    }

    @Test
    func `Custom endpoint already containing /v1/messages preserves path`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com/v1/messages")
        #expect(url.absoluteString == "https://my-proxy.com/v1/messages")
    }

    @Test
    func `Custom endpoint containing /messages preserves path`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com/api/messages")
        #expect(url.absoluteString == "https://my-proxy.com/api/messages")
    }

    @Test
    func `Custom endpoint with port appends path`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://my-proxy.com:8080")
        #expect(url.absoluteString == "https://my-proxy.com:8080/v1/messages")
    }

    // MARK: - Localhost Development Tests

    @Test
    func `HTTP localhost is allowed for development`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "http://localhost:8080")
        #expect(url.absoluteString == "http://localhost:8080/v1/messages")
    }

    @Test
    func `HTTP 127.0.0.1 is allowed for development`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "http://127.0.0.1:8080")
        #expect(url.absoluteString == "http://127.0.0.1:8080/v1/messages")
    }

    @Test
    func `HTTPS localhost is allowed`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "https://localhost:8080")
        #expect(url.absoluteString == "https://localhost:8080/v1/messages")
    }

    // MARK: - Error Cases

    @Test
    func `HTTP non-localhost is allowed`() throws {
        let url = try AnthropicEndpointResolver.messagesURL(customEndpoint: "http://insecure.com")
        #expect(url.absoluteString == "http://insecure.com/v1/messages")
    }

    @Test
    func `Malformed URL throws error`() throws {
        #expect(throws: AynaError.self) {
            _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: "not-a-url")
        }
    }

    @Test
    func `URL with invalid scheme throws error`() throws {
        #expect(throws: AynaError.self) {
            _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: "ftp://example.com")
        }
    }

    @Test
    func `URL without scheme throws error`() throws {
        #expect(throws: AynaError.self) {
            _ = try AnthropicEndpointResolver.messagesURL(customEndpoint: "example.com/api")
        }
    }
}
