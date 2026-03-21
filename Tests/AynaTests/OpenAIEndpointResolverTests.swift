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

    @Test("HTTP non-localhost endpoint is allowed")
    func httpNonLocalhostEndpointIsAllowed() throws {
        let config = OpenAIEndpointResolver.EndpointConfig(
            modelName: "gpt-5",
            provider: .openai,
            customEndpoint: "http://insecure.example.com"
        )

        let url = try OpenAIEndpointResolver.chatCompletionsURL(for: config)

        #expect(url == "http://insecure.example.com/v1/chat/completions")
    }
}
