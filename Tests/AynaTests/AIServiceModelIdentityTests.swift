@testable import Ayna
import Foundation
import Testing

extension AIServiceGlobalStateTests {
    @Suite("AIService Model Identity Tests", .tags(.fast), .serialized)
    @MainActor
    struct AIServiceModelIdentityTests {
        private let previousDefaults: UserDefaults
        private let previousKeychain: KeychainStoring

        init() {
            previousDefaults = AppPreferences.storage
            previousKeychain = AIService.keychain

            let suiteName = "AIServiceModelIdentityTests"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                fatalError("Failed to create UserDefaults suite for \(suiteName)")
            }
            defaults.removePersistentDomain(forName: suiteName)
            AppPreferences.use(defaults)
            AIService.keychain = InMemoryKeychainStorage()
        }

        @Test
        func `rename collision preserves both models and their settings`() {
            defer { restoreGlobalState() }
            let service = makeService()
            let source = "source-model"
            let destination = "destination-model"
            let sourceReasoning = ModelReasoningConfiguration(
                activation: .enabled,
                effort: .high,
                summary: .detailed
            )
            let destinationReasoning = ModelReasoningConfiguration(
                activation: .disabled,
                effort: .low,
                summary: .automatic
            )

            service.customModels = [source, destination]
            service.selectedModel = source
            service.modelProviders = [source: .openai, destination: .anthropic]
            service.modelEndpoints = [source: "https://source.example", destination: "https://destination.example"]
            service.modelAPIKeys = [source: "source-key", destination: "destination-key"]
            service.modelEndpointTypes = [source: .responses, destination: .chatCompletions]
            service.modelReasoningConfigurations = [
                source: sourceReasoning,
                destination: destinationReasoning,
            ]

            let expectedModels = service.customModels
            let expectedProviders = service.modelProviders
            let expectedEndpoints = service.modelEndpoints
            let expectedAPIKeys = service.modelAPIKeys
            let expectedEndpointTypes = service.modelEndpointTypes
            let expectedReasoning = service.modelReasoningConfigurations

            let result = service.renameConfiguredModel(from: source, to: destination)

            #expect(result == .destinationExists)
            #expect(service.customModels == expectedModels)
            #expect(service.selectedModel == source)
            #expect(service.modelProviders == expectedProviders)
            #expect(service.modelEndpoints == expectedEndpoints)
            #expect(service.modelAPIKeys == expectedAPIKeys)
            #expect(service.modelEndpointTypes == expectedEndpointTypes)
            #expect(service.modelReasoningConfigurations == expectedReasoning)
        }

        @Test
        func `renaming the selected Anthropic model updates selection and settings keys`() {
            defer { restoreGlobalState() }
            let service = makeService()
            let oldName = "claude-old"
            let newName = "claude-new"
            let otherModel = "other-model"
            let reasoning = ModelReasoningConfiguration(
                activation: .enabled,
                effort: .high,
                summary: .detailed
            )

            service.customModels = [oldName, otherModel]
            service.selectedModel = oldName
            service.modelProviders = [oldName: .anthropic, otherModel: .openai]
            service.modelEndpoints = [oldName: "https://anthropic.example"]
            service.modelAPIKeys = [oldName: "anthropic-key"]
            service.modelEndpointTypes = [otherModel: .responses]
            service.modelReasoningConfigurations = [oldName: reasoning]

            let result = service.renameConfiguredModel(from: oldName, to: newName)

            #expect(result == .renamed)
            #expect(service.customModels == [newName, otherModel])
            #expect(service.selectedModel == newName)
            #expect(service.modelProviders[oldName] == nil)
            #expect(service.modelProviders[newName] == .anthropic)
            #expect(service.modelEndpoints[oldName] == nil)
            #expect(service.modelEndpoints[newName] == "https://anthropic.example")
            #expect(service.modelAPIKeys[oldName] == nil)
            #expect(service.modelAPIKeys[newName] == "anthropic-key")
            #expect(service.modelReasoningConfigurations[oldName] == nil)
            #expect(service.modelReasoningConfigurations[newName] == reasoning)
        }

        @Test
        func `removing the final selected model clears selection and per-model settings`() {
            defer { restoreGlobalState() }
            let service = makeService()
            let model = "only-model"
            let reasoning = ModelReasoningConfiguration(
                activation: .enabled,
                effort: .medium,
                summary: .automatic
            )

            service.customModels = [model]
            service.selectedModel = model
            service.modelProviders = [model: .openai]
            service.modelEndpoints = [model: "https://only.example"]
            service.modelAPIKeys = [model: "only-key"]
            service.modelEndpointTypes = [model: .responses]
            service.modelReasoningConfigurations = [model: reasoning]

            service.removeConfiguredModel(model)

            #expect(service.customModels.isEmpty)
            #expect(service.selectedModel.isEmpty)
            #expect(service.modelProviders[model] == nil)
            #expect(service.modelEndpoints[model] == nil)
            #expect(service.modelAPIKeys[model] == nil)
            #expect(service.modelEndpointTypes[model] == nil)
            #expect(service.modelReasoningConfigurations[model] == nil)
        }

        private func makeService() -> AIService {
            AIService(urlSession: URLSession(configuration: .ephemeral))
        }

        private func restoreGlobalState() {
            AppPreferences.use(previousDefaults)
            AIService.keychain = previousKeychain
        }
    }
}
