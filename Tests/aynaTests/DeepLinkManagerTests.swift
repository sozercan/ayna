import Foundation
import Testing

@testable import Ayna

@Suite("DeepLinkManager Tests")
@MainActor
struct DeepLinkManagerTests {
    // MARK: - Helper

    /// Creates a fresh manager and service for each test, resetting state
    private func makeManager() -> (manager: DeepLinkManager, service: OpenAIService) {
        let service = OpenAIService.shared
        service.customModels = []
        service.modelProviders = [:]
        service.modelEndpoints = [:]
        service.modelAPIKeys = [:]
        service.modelEndpointTypes = [:]
        let manager = DeepLinkManager(openAIService: service)
        return (manager, service)
    }

    // MARK: - URL Parsing Tests

    @Test("Parse add-model with all parameters")
    func parseAddModelWithAllParameters() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=gpt-4o&provider=openai&endpoint=https://api.example.com&key=sk-test&type=chat")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingAddModel?.name == "gpt-4o")
        #expect(manager.pendingAddModel?.provider == .openai)
        #expect(manager.pendingAddModel?.endpoint == "https://api.example.com")
        #expect(manager.pendingAddModel?.apiKey == "sk-test")
        #expect(manager.pendingAddModel?.endpointType == .chatCompletions)
        #expect(manager.errorMessage == nil)
    }

    @Test("Parse add-model with minimal parameters")
    func parseAddModelWithMinimalParameters() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=my-model")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingAddModel?.name == "my-model")
        #expect(manager.pendingAddModel?.provider == .openai) // Default
        #expect(manager.pendingAddModel?.endpointType == .chatCompletions) // Default
        #expect(manager.pendingAddModel?.endpoint == nil)
        #expect(manager.pendingAddModel?.apiKey == nil)
        #expect(manager.errorMessage == nil)
    }

    @Test("Parse add-model missing name shows error")
    func parseAddModelMissingNameShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?provider=openai")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("name") ?? false)
    }

    @Test("Parse add-model empty name shows error")
    func parseAddModelEmptyNameShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
    }

    @Test("Parse add-model invalid provider shows error")
    func parseAddModelInvalidProviderShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=invalid-provider")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("provider") ?? false)
    }

    @Test("Parse add-model invalid endpoint type shows error")
    func parseAddModelInvalidEndpointTypeShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&type=invalid-type")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("type") ?? false)
    }

    // MARK: - Provider Parsing Tests

    @Test("Parse provider OpenAI")
    func parseProviderOpenAI() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=openai")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .openai)
    }

    @Test("Parse provider GitHub")
    func parseProviderGitHub() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=github")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .githubModels)
    }

    @Test("Parse provider githubmodels")
    func parseProviderGitHubModels() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=githubmodels")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .githubModels)
    }

    @Test("Parse provider Apple")
    func parseProviderApple() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=apple")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .appleIntelligence)
    }

    @Test("Parse provider AIKit")
    func parseProviderAIKit() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=aikit")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .aikit)
    }

    @Test("Parse provider local")
    func parseProviderLocal() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=local")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .aikit)
    }

    @Test("Parse provider case insensitive")
    func parseProviderCaseInsensitive() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=OpenAI")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .openai)
    }

    // MARK: - Endpoint Type Parsing Tests

    @Test("Parse endpoint type chat")
    func parseEndpointTypeChat() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&type=chat")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .chatCompletions)
    }

    @Test("Parse endpoint type chatcompletions")
    func parseEndpointTypeChatCompletions() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&type=chatcompletions")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .chatCompletions)
    }

    @Test("Parse endpoint type responses")
    func parseEndpointTypeResponses() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&type=responses")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .responses)
    }

    @Test("Parse endpoint type image")
    func parseEndpointTypeImage() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&type=image")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .imageGeneration)
    }

    @Test("Parse endpoint type imagegeneration")
    func parseEndpointTypeImageGeneration() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&type=imagegeneration")!
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .imageGeneration)
    }

    // MARK: - Chat URL Tests

    @Test("Parse chat with all parameters")
    func parseChatWithAllParameters() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?model=gpt-4o&prompt=Hello%20world&system=You%20are%20helpful")!

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "gpt-4o")
        #expect(manager.pendingChat?.prompt == "Hello world")
        #expect(manager.pendingChat?.systemPrompt == "You are helpful")
        #expect(manager.errorMessage == nil)
    }

    @Test("Parse chat with model only")
    func parseChatWithModelOnly() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?model=claude-3")!

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "claude-3")
        #expect(manager.pendingChat?.prompt == nil)
        #expect(manager.pendingChat?.systemPrompt == nil)
    }

    @Test("Parse chat with prompt only")
    func parseChatWithPromptOnly() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?prompt=What%20is%20the%20weather")!

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == nil)
        #expect(manager.pendingChat?.prompt == "What is the weather")
        #expect(manager.pendingChat?.systemPrompt == nil)
    }

    @Test("Parse chat with no parameters")
    func parseChatWithNoParameters() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat")!

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == nil)
        #expect(manager.pendingChat?.prompt == nil)
        #expect(manager.pendingChat?.systemPrompt == nil)
        #expect(manager.errorMessage == nil)
    }

    // MARK: - Invalid URL Tests

    @Test("Invalid scheme shows error")
    func invalidSchemeShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "https://add-model?name=test")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
    }

    @Test("Unknown action shows error")
    func unknownActionShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://unknown-action")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("Unknown action") ?? false)
    }

    // MARK: - Confirm/Cancel Tests

    @Test("Confirm add model adds model")
    func confirmAddModelAddsModel() async {
        let (manager, service) = makeManager()
        let url = URL(string: "ayna://add-model?name=test-model&provider=openai&endpoint=https://api.test.com&key=test-key")!
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)

        manager.confirmAddModel()

        #expect(manager.pendingAddModel == nil)
        #expect(service.customModels.contains("test-model"))
        #expect(service.modelProviders["test-model"] == .openai)
        #expect(service.modelEndpoints["test-model"] == "https://api.test.com")
        #expect(service.modelAPIKeys["test-model"] == "test-key")
    }

    @Test("Confirm add model without endpoint does not set endpoint")
    func confirmAddModelWithoutEndpointDoesNotSetEndpoint() async {
        let (manager, service) = makeManager()
        let url = URL(string: "ayna://add-model?name=test-model&provider=github")!
        await manager.handle(url: url)

        manager.confirmAddModel()

        #expect(service.customModels.contains("test-model"))
        #expect(service.modelEndpoints["test-model"] == nil)
    }

    @Test("Confirm add model without key does not set key")
    func confirmAddModelWithoutKeyDoesNotSetKey() async {
        let (manager, service) = makeManager()
        let url = URL(string: "ayna://add-model?name=test-model")!
        await manager.handle(url: url)

        manager.confirmAddModel()

        #expect(service.customModels.contains("test-model"))
        #expect(service.modelAPIKeys["test-model"] == nil)
    }

    @Test("Cancel add model clears pending request")
    func cancelAddModelClearsPendingRequest() async {
        let (manager, service) = makeManager()
        let url = URL(string: "ayna://add-model?name=test-model")!
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)

        manager.cancelAddModel()

        #expect(manager.pendingAddModel == nil)
        #expect(!service.customModels.contains("test-model"))
    }

    @Test("Confirm add model duplicate shows error")
    func confirmAddModelDuplicateShowsError() async {
        let (manager, _) = makeManager()
        // Add first model
        let url1 = URL(string: "ayna://add-model?name=duplicate-model")!
        await manager.handle(url: url1)
        manager.confirmAddModel()

        // Try to add duplicate
        let url2 = URL(string: "ayna://add-model?name=duplicate-model")!
        await manager.handle(url: url2)
        manager.confirmAddModel()

        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("already exists") ?? false)
    }

    // MARK: - Error Handling Tests

    @Test("Dismiss error clears error")
    func dismissErrorClearsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://unknown-action")!
        await manager.handle(url: url)

        #expect(manager.errorMessage != nil)

        manager.dismissError()

        #expect(manager.errorMessage == nil)
        #expect(manager.errorRecoverySuggestion == nil)
    }

    @Test("Clear pending chat clears request")
    func clearPendingChatClearsRequest() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?prompt=test")!
        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)

        manager.clearPendingChat()

        #expect(manager.pendingChat == nil)
    }

    @Test("New URL clears previous error")
    func newURLClearsPreviousError() async {
        let (manager, _) = makeManager()
        // First cause an error
        let badURL = URL(string: "ayna://unknown")!
        await manager.handle(url: badURL)
        #expect(manager.errorMessage != nil)

        // Then handle a valid URL
        let goodURL = URL(string: "ayna://chat?prompt=hello")!
        await manager.handle(url: goodURL)

        #expect(manager.errorMessage == nil)
        #expect(manager.pendingChat != nil)
    }

    // MARK: - OAuth Callback Tests

    @Test("OAuth callback is recognized")
    func oAuthCallbackIsRecognized() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://auth/callback?code=test-code")!

        await manager.handle(url: url)

        // OAuth callbacks don't set pending states, they're delegated
        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage == nil)
    }

    // MARK: - Main Action Tests

    @Test("Main action creates chat request")
    func mainActionCreatesChatRequest() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://main")!

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == nil)
        #expect(manager.pendingChat?.prompt == nil)
        #expect(manager.errorMessage == nil)
    }

    // MARK: - Display Property Tests

    @Test("Show add model confirmation property")
    func showAddModelConfirmationProperty() async {
        let (manager, _) = makeManager()
        #expect(!manager.showAddModelConfirmation)

        let url = URL(string: "ayna://add-model?name=test")!
        await manager.handle(url: url)

        #expect(manager.showAddModelConfirmation)

        manager.cancelAddModel()

        #expect(!manager.showAddModelConfirmation)
    }

    @Test("Add model request display properties")
    func addModelRequestDisplayProperties() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=test&provider=github&type=responses")!
        await manager.handle(url: url)

        #expect(manager.pendingAddModel?.displayProvider == AIProvider.githubModels.displayName)
        #expect(manager.pendingAddModel?.displayEndpointType == APIEndpointType.responses.displayName)
    }

    // MARK: - URL Encoding Tests

    @Test("URL encoded parameters are parsed correctly")
    func urlEncodedParametersAreParsedCorrectly() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?prompt=Hello%20World%21%20How%20are%20you%3F")!

        await manager.handle(url: url)

        #expect(manager.pendingChat?.prompt == "Hello World! How are you?")
    }

    @Test("Special characters in model name")
    func specialCharactersInModelName() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://add-model?name=gpt-4o-2024-05-13")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel?.name == "gpt-4o-2024-05-13")
    }

    // MARK: - Unified Add+Chat Flow Tests

    @Test("Unified flow chat with model config shows add confirmation")
    func unifiedFlowChatWithModelConfigShowsAddConfirmation() async {
        let (manager, _) = makeManager()
        // Model doesn't exist, should show add confirmation
        let url = URL(string: "ayna://chat?model=new-model&provider=openai&endpoint=https://api.test.com&prompt=Hello")!

        await manager.handle(url: url)

        // Should have both pending add model AND pending chat
        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingChat != nil)
        #expect(manager.pendingAddModel?.name == "new-model")
        #expect(manager.pendingAddModel?.provider == .openai)
        #expect(manager.pendingAddModel?.endpoint == "https://api.test.com")
        #expect(manager.pendingChat?.prompt == "Hello")
        #expect(manager.errorMessage == nil)
    }

    @Test("Unified flow confirm adds model and preserves chat")
    func unifiedFlowConfirmAddsModelAndPreservesChat() async {
        let (manager, service) = makeManager()
        let url = URL(string: "ayna://chat?model=unified-model&provider=github&key=test-key&prompt=Test%20prompt")!
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingChat != nil)

        manager.confirmAddModel()

        // Model should be added
        #expect(service.customModels.contains("unified-model"))
        #expect(service.modelProviders["unified-model"] == .githubModels)
        #expect(service.modelAPIKeys["unified-model"] == "test-key")

        // Add model confirmation cleared, but chat preserved
        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.prompt == "Test prompt")
    }

    @Test("Unified flow cancel clears both pending requests")
    func unifiedFlowCancelClearsBothPendingRequests() async {
        let (manager, service) = makeManager()
        let url = URL(string: "ayna://chat?model=cancel-model&provider=openai&prompt=Test")!
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingChat != nil)

        manager.cancelAddModel()

        // Both should be cleared
        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(!service.customModels.contains("cancel-model"))
    }

    @Test("Unified flow existing model skips add confirmation")
    func unifiedFlowExistingModelSkipsAddConfirmation() async {
        let (manager, service) = makeManager()
        // First add a model
        service.customModels.append("existing-model")

        // Now try unified flow with same model name
        let url = URL(string: "ayna://chat?model=existing-model&provider=openai&prompt=Hello")!
        await manager.handle(url: url)

        // Should skip add confirmation since model exists
        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "existing-model")
        #expect(manager.pendingChat?.prompt == "Hello")
    }

    @Test("Unified flow with all config params")
    func unifiedFlowWithAllConfigParams() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?model=full-config&provider=aikit&endpoint=http://localhost:8080&key=local-key&type=responses&prompt=Test&system=Be%20helpful")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingAddModel?.name == "full-config")
        #expect(manager.pendingAddModel?.provider == .aikit)
        #expect(manager.pendingAddModel?.endpoint == "http://localhost:8080")
        #expect(manager.pendingAddModel?.apiKey == "local-key")
        #expect(manager.pendingAddModel?.endpointType == .responses)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "full-config")
        #expect(manager.pendingChat?.prompt == "Test")
        #expect(manager.pendingChat?.systemPrompt == "Be helpful")
    }

    @Test("Unified flow model config is stored")
    func unifiedFlowModelConfigIsStored() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?model=config-test&provider=github&prompt=Hello")!

        await manager.handle(url: url)

        // Verify modelConfig is set on the chat request
        #expect(manager.pendingChat?.modelConfig != nil)
        #expect(manager.pendingChat?.modelConfig?.name == "config-test")
        #expect(manager.pendingChat?.modelConfig?.provider == .githubModels)
    }

    @Test("Unified flow invalid provider shows error")
    func unifiedFlowInvalidProviderShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?model=test&provider=invalid&prompt=Hello")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("provider") ?? false)
    }

    @Test("Unified flow invalid type shows error")
    func unifiedFlowInvalidTypeShowsError() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?model=test&type=invalid&prompt=Hello")!

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("type") ?? false)
    }

    @Test("Chat without config params has no model config")
    func chatWithoutConfigParamsHasNoModelConfig() async {
        let (manager, _) = makeManager()
        let url = URL(string: "ayna://chat?model=simple-model&prompt=Hello")!

        await manager.handle(url: url)

        // No config params, so no add model flow
        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.modelConfig == nil)
        #expect(manager.pendingChat?.model == "simple-model")
    }
}
