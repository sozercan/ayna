@testable import Ayna
import Foundation
import Testing

@Suite("Anthropic Provider Configuration Tests")
@MainActor
struct AnthropicProviderConfigurationTests {
    private func makeProvider() -> AnthropicProvider {
        AnthropicProvider(urlSession: URLSession(configuration: .ephemeral))
    }

    private func makeConfig(
        model: String = "claude-sonnet-4-20250514",
        apiKey: String = "test-api-key"
    ) -> AIProviderRequestConfig {
        AIProviderRequestConfig(model: model, apiKey: apiKey)
    }

    @Test
    func `factory returns AnthropicProvider for .anthropic`() {
        let provider = AIProviderFactory.createProvider(
            for: .anthropic,
            urlSession: URLSession(configuration: .ephemeral)
        )

        #expect(provider.providerType == .anthropic)
        #expect(provider is AnthropicProvider)
    }

    @Test
    func `provider type is anthropic`() {
        #expect(makeProvider().providerType == .anthropic)
    }

    @Test
    func `provider requires API key`() {
        #expect(makeProvider().requiresAPIKey)
    }

    @Test
    func `validation fails with empty API key`() {
        #expect(makeProvider().validateConfiguration(makeConfig(apiKey: "")) != nil)
    }

    @Test
    func `validation fails with empty model`() {
        #expect(makeProvider().validateConfiguration(makeConfig(model: "")) != nil)
    }

    @Test
    func `validation passes with valid config`() {
        #expect(makeProvider().validateConfiguration(makeConfig()) == nil)
    }
}
