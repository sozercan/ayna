@testable import Ayna
import Foundation
import Testing

@MainActor
private final class CapturingAnthropicProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .anthropic
    let requiresAPIKey: Bool = true
    var lastConfig: AIProviderRequestConfig?

    func sendMessage(
        messages _: [Message],
        config: AIProviderRequestConfig,
        stream _: Bool,
        tools _: [[String: Any]]?,
        callbacks: AIProviderStreamCallbacks
    ) {
        lastConfig = config
        callbacks.onComplete()
    }

    func cancelRequest() {}
}

extension AIServiceGlobalStateTests {
    @Suite("Anthropic Provider Configuration Tests", .serialized)
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

        private func withIsolatedPreferences<T>(_ body: (UserDefaults) async throws -> T) async rethrows -> T {
            let suiteName = "AnthropicProviderConfigurationTests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let previousStorage = AppPreferences.storage
            let previousKeychain = AIService.keychain
            AppPreferences.use(defaults)
            AIService.keychain = InMemoryKeychainStorage()
            defer {
                AIService.keychain = previousKeychain
                AppPreferences.use(previousStorage)
                defaults.removePersistentDomain(forName: suiteName)
            }
            return try await body(defaults)
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

        @Test
        func `thinking budget presets map values cleanly`() {
            #expect(AnthropicThinkingBudget.off.budgetTokens == nil)
            #expect(AnthropicThinkingBudget.low.budgetTokens == 4096)
            #expect(AnthropicThinkingBudget.medium.budgetTokens == 10000)
            #expect(AnthropicThinkingBudget.high.budgetTokens == 16000)
            #expect(AnthropicThinkingBudget.max.budgetTokens == 32000)

            #expect(AnthropicThinkingBudget.preset(for: nil) == .off)
            #expect(AnthropicThinkingBudget.preset(for: 0) == .off)
            #expect(AnthropicThinkingBudget.preset(for: 512) == .off)
            #expect(AnthropicThinkingBudget.preset(for: 4096) == .low)
            #expect(AnthropicThinkingBudget.preset(for: 10000) == .medium)
            #expect(AnthropicThinkingBudget.preset(for: 16000) == .high)
            #expect(AnthropicThinkingBudget.preset(for: 32000) == .max)
            #expect(AnthropicThinkingBudget.preset(for: 12000) == .medium)
        }

        @Test
        func `thinking budget defaults to nil and persists per model`() async {
            await withIsolatedPreferences { _ in
                let model = "claude-sonnet-4-20250514"
                let service = AIService()
                #expect(service.thinkingBudget(for: model) == nil)

                service.modelThinkingBudgets[model] = AnthropicThinkingBudget.medium.rawValue
                #expect(service.thinkingBudget(for: model) == 10000)

                let reloadedService = AIService()
                #expect(reloadedService.modelThinkingBudgets[model] == 10000)
                #expect(reloadedService.thinkingBudget(for: model) == 10000)

                reloadedService.modelThinkingBudgets.removeValue(forKey: model)
                let clearedService = AIService()
                #expect(clearedService.thinkingBudget(for: model) == nil)
            }
        }

        @Test
        func `sub-minimum persisted thinking budget is ignored`() async {
            await withIsolatedPreferences { defaults in
                let model = "claude-sonnet-4-20250514"
                defaults.set([model: 512], forKey: "modelThinkingBudgets")

                let service = AIService()
                #expect(service.modelThinkingBudgets[model] == nil)
                #expect(service.thinkingBudget(for: model) == nil)
            }
        }

        @Test(.timeLimit(.minutes(1)))
        func `AIService passes configured thinking budget to AnthropicProvider`() async {
            await withIsolatedPreferences { _ in
                let provider = CapturingAnthropicProvider()
                let service = AIService(anthropicProviderFactory: { _ in provider })
                let model = "claude-sonnet-4-20250514"
                service.customModels = [model]
                service.selectedModel = model
                service.modelProviders[model] = .anthropic
                service.modelAPIKeys[model] = "sk-ant-test"

                await confirmation("Default nil thinking budget completes") { completed in
                    service.sendMessage(
                        messages: [Message(role: .user, content: "Hello")],
                        model: model,
                        stream: false,
                        onChunk: { _ in },
                        onComplete: { completed() },
                        onError: { error in Issue.record("Unexpected error: \(error)") }
                    )
                    try? await Task.sleep(for: .milliseconds(100))
                }
                #expect(provider.lastConfig?.thinkingBudget == nil)

                service.modelThinkingBudgets[model] = AnthropicThinkingBudget.high.rawValue

                await confirmation("Configured thinking budget completes") { completed in
                    service.sendMessage(
                        messages: [Message(role: .user, content: "Think deeply")],
                        model: model,
                        stream: false,
                        onChunk: { _ in },
                        onComplete: { completed() },
                        onError: { error in Issue.record("Unexpected error: \(error)") }
                    )
                    try? await Task.sleep(for: .milliseconds(100))
                }
                #expect(provider.lastConfig?.thinkingBudget == 16000)
            }
        }
    }
}
