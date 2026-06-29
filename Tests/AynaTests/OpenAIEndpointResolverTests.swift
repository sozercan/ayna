//
//  OpenAIEndpointResolverTests.swift
//  aynaTests
//
//  Created on 3/17/26.
//

@testable import Ayna
import Testing

@Suite(.tags(.fast, .errorHandling))
struct OpenAIEndpointResolverTests {
    @Test("Default OpenAI chat endpoint returns the platform URL")
    func defaultOpenAIChatEndpointReturnsThePlatformURL() throws {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai
        )

        let url = try OpenAIEndpointResolver.chatCompletionsURL(for: config)

        #expect(url == "https://api.openai.com/v1/chat/completions")
    }

    @Test("Custom HTTPS endpoint appends the chat completions path")
    func customHTTPSEndpointAppendsTheChatCompletionsPath() throws {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "https://my-proxy.example.com"
        )

        let url = try OpenAIEndpointResolver.chatCompletionsURL(for: config)

        #expect(url == "https://my-proxy.example.com/v1/chat/completions")
    }

    @Test("HTTP localhost endpoint is allowed for development")
    func httpLocalhostEndpointIsAllowedForDevelopment() throws {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "http://localhost:8000"
        )

        let url = try OpenAIEndpointResolver.chatCompletionsURL(for: config)

        #expect(url == "http://localhost:8000/v1/chat/completions")
    }

    @Test("HTTP loopback endpoint is allowed for development")
    func httpLoopbackEndpointIsAllowedForDevelopment() throws {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "http://127.0.0.1:8000"
        )

        let url = try OpenAIEndpointResolver.chatCompletionsURL(for: config)

        #expect(url == "http://127.0.0.1:8000/v1/chat/completions")
    }

    @Test("HTTP IPv6 loopback endpoint is allowed for development")
    func httpIPv6LoopbackEndpointIsAllowedForDevelopment() throws {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "http://[::1]:8000"
        )

        let url = try OpenAIEndpointResolver.chatCompletionsURL(for: config)

        #expect(url == "http://[::1]:8000/v1/chat/completions")
    }

    @Test("HTTP non-localhost endpoint is rejected")
    func httpNonLocalhostEndpointIsRejected() {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "http://insecure.example.com"
        )

        #expect(throws: AynaError.self) {
            _ = try OpenAIEndpointResolver.chatCompletionsURL(for: config)
        }
    }

    @Test("Malformed custom endpoint throws error")
    func malformedCustomEndpointThrowsError() {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "not-a-url"
        )

        #expect(throws: AynaError.self) {
            _ = try OpenAIEndpointResolver.chatCompletionsURL(for: config)
        }
    }

    @Test("Custom endpoint with invalid scheme throws error")
    func customEndpointWithInvalidSchemeThrowsError() {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "ftp://example.com"
        )

        #expect(throws: AynaError.self) {
            _ = try OpenAIEndpointResolver.chatCompletionsURL(for: config)
        }
    }

    @Test("Custom endpoint API key requirement is centralized")
    func customEndpointAPIKeyRequirementIsCentralized() {
        #expect(OpenAIEndpointResolver.customEndpointRequiresAPIKey(nil))
        #expect(OpenAIEndpointResolver.customEndpointRequiresAPIKey("https://api.openai.com"))
        #expect(OpenAIEndpointResolver.customEndpointRequiresAPIKey("https://resource.openai.azure.com"))
        #expect(!OpenAIEndpointResolver.customEndpointRequiresAPIKey("https://proxy.example.com"))
    }
}
