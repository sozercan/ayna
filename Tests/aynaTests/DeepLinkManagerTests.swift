@testable import Ayna
import XCTest

@MainActor
final class DeepLinkManagerTests: XCTestCase {
    private var manager: DeepLinkManager!
    private var mockService: OpenAIService!

    override func setUp() async throws {
        try await super.setUp()
        mockService = OpenAIService.shared
        // Clear any existing custom models
        mockService.customModels = []
        mockService.modelProviders = [:]
        mockService.modelEndpoints = [:]
        mockService.modelAPIKeys = [:]
        mockService.modelEndpointTypes = [:]
        manager = DeepLinkManager(openAIService: mockService)
    }

    override func tearDown() async throws {
        manager = nil
        mockService.customModels = []
        mockService.modelProviders = [:]
        mockService.modelEndpoints = [:]
        mockService.modelAPIKeys = [:]
        mockService.modelEndpointTypes = [:]
        try await super.tearDown()
    }

    // MARK: - URL Parsing Tests

    @MainActor
    func testParseAddModelWithAllParameters() async {
        let url = URL(string: "ayna://add-model?name=gpt-4o&provider=openai&endpoint=https://api.example.com&key=sk-test&type=chat")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingAddModel)
        XCTAssertEqual(manager.pendingAddModel?.name, "gpt-4o")
        XCTAssertEqual(manager.pendingAddModel?.provider, .openai)
        XCTAssertEqual(manager.pendingAddModel?.endpoint, "https://api.example.com")
        XCTAssertEqual(manager.pendingAddModel?.apiKey, "sk-test")
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .chatCompletions)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testParseAddModelWithMinimalParameters() async {
        let url = URL(string: "ayna://add-model?name=my-model")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingAddModel)
        XCTAssertEqual(manager.pendingAddModel?.name, "my-model")
        XCTAssertEqual(manager.pendingAddModel?.provider, .openai) // Default
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .chatCompletions) // Default
        XCTAssertNil(manager.pendingAddModel?.endpoint)
        XCTAssertNil(manager.pendingAddModel?.apiKey)
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testParseAddModelMissingNameShowsError() async {
        let url = URL(string: "ayna://add-model?provider=openai")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("name") ?? false)
    }

    @MainActor
    func testParseAddModelEmptyNameShowsError() async {
        let url = URL(string: "ayna://add-model?name=")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testParseAddModelInvalidProviderShowsError() async {
        let url = URL(string: "ayna://add-model?name=test&provider=invalid-provider")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("provider") ?? false)
    }

    @MainActor
    func testParseAddModelInvalidEndpointTypeShowsError() async {
        let url = URL(string: "ayna://add-model?name=test&type=invalid-type")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("type") ?? false)
    }

    // MARK: - Provider Parsing Tests

    @MainActor
    func testParseProviderOpenAI() async {
        let url = URL(string: "ayna://add-model?name=test&provider=openai")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.provider, .openai)
    }

    @MainActor
    func testParseProviderGitHub() async {
        let url = URL(string: "ayna://add-model?name=test&provider=github")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.provider, .githubModels)
    }

    @MainActor
    func testParseProviderGitHubModels() async {
        let url = URL(string: "ayna://add-model?name=test&provider=githubmodels")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.provider, .githubModels)
    }

    @MainActor
    func testParseProviderApple() async {
        let url = URL(string: "ayna://add-model?name=test&provider=apple")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.provider, .appleIntelligence)
    }

    @MainActor
    func testParseProviderAIKit() async {
        let url = URL(string: "ayna://add-model?name=test&provider=aikit")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.provider, .aikit)
    }

    @MainActor
    func testParseProviderLocal() async {
        let url = URL(string: "ayna://add-model?name=test&provider=local")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.provider, .aikit)
    }

    @MainActor
    func testParseProviderCaseInsensitive() async {
        let url = URL(string: "ayna://add-model?name=test&provider=OpenAI")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.provider, .openai)
    }

    // MARK: - Endpoint Type Parsing Tests

    @MainActor
    func testParseEndpointTypeChat() async {
        let url = URL(string: "ayna://add-model?name=test&type=chat")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .chatCompletions)
    }

    @MainActor
    func testParseEndpointTypeChatCompletions() async {
        let url = URL(string: "ayna://add-model?name=test&type=chatcompletions")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .chatCompletions)
    }

    @MainActor
    func testParseEndpointTypeResponses() async {
        let url = URL(string: "ayna://add-model?name=test&type=responses")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .responses)
    }

    @MainActor
    func testParseEndpointTypeImage() async {
        let url = URL(string: "ayna://add-model?name=test&type=image")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .imageGeneration)
    }

    @MainActor
    func testParseEndpointTypeImageGeneration() async {
        let url = URL(string: "ayna://add-model?name=test&type=imagegeneration")!
        await manager.handle(url: url)
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .imageGeneration)
    }

    // MARK: - Chat URL Tests

    @MainActor
    func testParseChatWithAllParameters() async {
        let url = URL(string: "ayna://chat?model=gpt-4o&prompt=Hello%20world&system=You%20are%20helpful")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingChat)
        XCTAssertEqual(manager.pendingChat?.model, "gpt-4o")
        XCTAssertEqual(manager.pendingChat?.prompt, "Hello world")
        XCTAssertEqual(manager.pendingChat?.systemPrompt, "You are helpful")
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testParseChatWithModelOnly() async {
        let url = URL(string: "ayna://chat?model=claude-3")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingChat)
        XCTAssertEqual(manager.pendingChat?.model, "claude-3")
        XCTAssertNil(manager.pendingChat?.prompt)
        XCTAssertNil(manager.pendingChat?.systemPrompt)
    }

    @MainActor
    func testParseChatWithPromptOnly() async {
        let url = URL(string: "ayna://chat?prompt=What%20is%20the%20weather")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingChat)
        XCTAssertNil(manager.pendingChat?.model)
        XCTAssertEqual(manager.pendingChat?.prompt, "What is the weather")
        XCTAssertNil(manager.pendingChat?.systemPrompt)
    }

    @MainActor
    func testParseChatWithNoParameters() async {
        let url = URL(string: "ayna://chat")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingChat)
        XCTAssertNil(manager.pendingChat?.model)
        XCTAssertNil(manager.pendingChat?.prompt)
        XCTAssertNil(manager.pendingChat?.systemPrompt)
        XCTAssertNil(manager.errorMessage)
    }

    // MARK: - Invalid URL Tests

    @MainActor
    func testInvalidSchemeShowsError() async {
        let url = URL(string: "https://add-model?name=test")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNil(manager.pendingChat)
        XCTAssertNotNil(manager.errorMessage)
    }

    @MainActor
    func testUnknownActionShowsError() async {
        let url = URL(string: "ayna://unknown-action")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNil(manager.pendingChat)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("Unknown action") ?? false)
    }

    // MARK: - Confirm/Cancel Tests

    @MainActor
    func testConfirmAddModelAddsModel() async {
        let url = URL(string: "ayna://add-model?name=test-model&provider=openai&endpoint=https://api.test.com&key=test-key")!
        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingAddModel)

        manager.confirmAddModel()

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertTrue(mockService.customModels.contains("test-model"))
        XCTAssertEqual(mockService.modelProviders["test-model"], .openai)
        XCTAssertEqual(mockService.modelEndpoints["test-model"], "https://api.test.com")
        XCTAssertEqual(mockService.modelAPIKeys["test-model"], "test-key")
    }

    @MainActor
    func testConfirmAddModelWithoutEndpointDoesNotSetEndpoint() async {
        let url = URL(string: "ayna://add-model?name=test-model&provider=github")!
        await manager.handle(url: url)

        manager.confirmAddModel()

        XCTAssertTrue(mockService.customModels.contains("test-model"))
        XCTAssertNil(mockService.modelEndpoints["test-model"])
    }

    @MainActor
    func testConfirmAddModelWithoutKeyDoesNotSetKey() async {
        let url = URL(string: "ayna://add-model?name=test-model")!
        await manager.handle(url: url)

        manager.confirmAddModel()

        XCTAssertTrue(mockService.customModels.contains("test-model"))
        XCTAssertNil(mockService.modelAPIKeys["test-model"])
    }

    @MainActor
    func testCancelAddModelClearsPendingRequest() async {
        let url = URL(string: "ayna://add-model?name=test-model")!
        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingAddModel)

        manager.cancelAddModel()

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertFalse(mockService.customModels.contains("test-model"))
    }

    @MainActor
    func testConfirmAddModelDuplicateShowsError() async {
        // Add first model
        let url1 = URL(string: "ayna://add-model?name=duplicate-model")!
        await manager.handle(url: url1)
        manager.confirmAddModel()

        // Try to add duplicate
        let url2 = URL(string: "ayna://add-model?name=duplicate-model")!
        await manager.handle(url: url2)
        manager.confirmAddModel()

        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("already exists") ?? false)
    }

    // MARK: - Error Handling Tests

    @MainActor
    func testDismissErrorClearsError() async {
        let url = URL(string: "ayna://unknown-action")!
        await manager.handle(url: url)

        XCTAssertNotNil(manager.errorMessage)

        manager.dismissError()

        XCTAssertNil(manager.errorMessage)
        XCTAssertNil(manager.errorRecoverySuggestion)
    }

    @MainActor
    func testClearPendingChatClearsRequest() async {
        let url = URL(string: "ayna://chat?prompt=test")!
        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingChat)

        manager.clearPendingChat()

        XCTAssertNil(manager.pendingChat)
    }

    @MainActor
    func testNewURLClearsPreviousError() async {
        // First cause an error
        let badURL = URL(string: "ayna://unknown")!
        await manager.handle(url: badURL)
        XCTAssertNotNil(manager.errorMessage)

        // Then handle a valid URL
        let goodURL = URL(string: "ayna://chat?prompt=hello")!
        await manager.handle(url: goodURL)

        XCTAssertNil(manager.errorMessage)
        XCTAssertNotNil(manager.pendingChat)
    }

    // MARK: - OAuth Callback Tests

    @MainActor
    func testOAuthCallbackIsRecognized() async {
        let url = URL(string: "ayna://auth/callback?code=test-code")!

        await manager.handle(url: url)

        // OAuth callbacks don't set pending states, they're delegated
        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNil(manager.errorMessage)
    }

    // MARK: - Main Action Tests

    @MainActor
    func testMainActionCreatesChatRequest() async {
        let url = URL(string: "ayna://main")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingChat)
        XCTAssertNil(manager.pendingChat?.model)
        XCTAssertNil(manager.pendingChat?.prompt)
        XCTAssertNil(manager.errorMessage)
    }

    // MARK: - Display Property Tests

    @MainActor
    func testShowAddModelConfirmationProperty() async {
        XCTAssertFalse(manager.showAddModelConfirmation)

        let url = URL(string: "ayna://add-model?name=test")!
        await manager.handle(url: url)

        XCTAssertTrue(manager.showAddModelConfirmation)

        manager.cancelAddModel()

        XCTAssertFalse(manager.showAddModelConfirmation)
    }

    @MainActor
    func testAddModelRequestDisplayProperties() async {
        let url = URL(string: "ayna://add-model?name=test&provider=github&type=responses")!
        await manager.handle(url: url)

        XCTAssertEqual(manager.pendingAddModel?.displayProvider, AIProvider.githubModels.displayName)
        XCTAssertEqual(manager.pendingAddModel?.displayEndpointType, APIEndpointType.responses.displayName)
    }

    // MARK: - URL Encoding Tests

    @MainActor
    func testURLEncodedParametersAreParsedCorrectly() async {
        let url = URL(string: "ayna://chat?prompt=Hello%20World%21%20How%20are%20you%3F")!

        await manager.handle(url: url)

        XCTAssertEqual(manager.pendingChat?.prompt, "Hello World! How are you?")
    }

    @MainActor
    func testSpecialCharactersInModelName() async {
        let url = URL(string: "ayna://add-model?name=gpt-4o-2024-05-13")!

        await manager.handle(url: url)

        XCTAssertEqual(manager.pendingAddModel?.name, "gpt-4o-2024-05-13")
    }

    // MARK: - Unified Add+Chat Flow Tests

    @MainActor
    func testUnifiedFlowChatWithModelConfigShowsAddConfirmation() async {
        // Model doesn't exist, should show add confirmation
        let url = URL(string: "ayna://chat?model=new-model&provider=openai&endpoint=https://api.test.com&prompt=Hello")!

        await manager.handle(url: url)

        // Should have both pending add model AND pending chat
        XCTAssertNotNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.pendingChat)
        XCTAssertEqual(manager.pendingAddModel?.name, "new-model")
        XCTAssertEqual(manager.pendingAddModel?.provider, .openai)
        XCTAssertEqual(manager.pendingAddModel?.endpoint, "https://api.test.com")
        XCTAssertEqual(manager.pendingChat?.prompt, "Hello")
        XCTAssertNil(manager.errorMessage)
    }

    @MainActor
    func testUnifiedFlowConfirmAddsModelAndPreservesChat() async {
        let url = URL(string: "ayna://chat?model=unified-model&provider=github&key=test-key&prompt=Test%20prompt")!
        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.pendingChat)

        manager.confirmAddModel()

        // Model should be added
        XCTAssertTrue(mockService.customModels.contains("unified-model"))
        XCTAssertEqual(mockService.modelProviders["unified-model"], .githubModels)
        XCTAssertEqual(mockService.modelAPIKeys["unified-model"], "test-key")

        // Add model confirmation cleared, but chat preserved
        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.pendingChat)
        XCTAssertEqual(manager.pendingChat?.prompt, "Test prompt")
    }

    @MainActor
    func testUnifiedFlowCancelClearsBothPendingRequests() async {
        let url = URL(string: "ayna://chat?model=cancel-model&provider=openai&prompt=Test")!
        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.pendingChat)

        manager.cancelAddModel()

        // Both should be cleared
        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNil(manager.pendingChat)
        XCTAssertFalse(mockService.customModels.contains("cancel-model"))
    }

    @MainActor
    func testUnifiedFlowExistingModelSkipsAddConfirmation() async {
        // First add a model
        mockService.customModels.append("existing-model")

        // Now try unified flow with same model name
        let url = URL(string: "ayna://chat?model=existing-model&provider=openai&prompt=Hello")!
        await manager.handle(url: url)

        // Should skip add confirmation since model exists
        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.pendingChat)
        XCTAssertEqual(manager.pendingChat?.model, "existing-model")
        XCTAssertEqual(manager.pendingChat?.prompt, "Hello")
    }

    @MainActor
    func testUnifiedFlowWithAllConfigParams() async {
        let url = URL(string: "ayna://chat?model=full-config&provider=aikit&endpoint=http://localhost:8080&key=local-key&type=responses&prompt=Test&system=Be%20helpful")!

        await manager.handle(url: url)

        XCTAssertNotNil(manager.pendingAddModel)
        XCTAssertEqual(manager.pendingAddModel?.name, "full-config")
        XCTAssertEqual(manager.pendingAddModel?.provider, .aikit)
        XCTAssertEqual(manager.pendingAddModel?.endpoint, "http://localhost:8080")
        XCTAssertEqual(manager.pendingAddModel?.apiKey, "local-key")
        XCTAssertEqual(manager.pendingAddModel?.endpointType, .responses)

        XCTAssertNotNil(manager.pendingChat)
        XCTAssertEqual(manager.pendingChat?.model, "full-config")
        XCTAssertEqual(manager.pendingChat?.prompt, "Test")
        XCTAssertEqual(manager.pendingChat?.systemPrompt, "Be helpful")
    }

    @MainActor
    func testUnifiedFlowModelConfigIsStored() async {
        let url = URL(string: "ayna://chat?model=config-test&provider=github&prompt=Hello")!

        await manager.handle(url: url)

        // Verify modelConfig is set on the chat request
        XCTAssertNotNil(manager.pendingChat?.modelConfig)
        XCTAssertEqual(manager.pendingChat?.modelConfig?.name, "config-test")
        XCTAssertEqual(manager.pendingChat?.modelConfig?.provider, .githubModels)
    }

    @MainActor
    func testUnifiedFlowInvalidProviderShowsError() async {
        let url = URL(string: "ayna://chat?model=test&provider=invalid&prompt=Hello")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNil(manager.pendingChat)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("provider") ?? false)
    }

    @MainActor
    func testUnifiedFlowInvalidTypeShowsError() async {
        let url = URL(string: "ayna://chat?model=test&type=invalid&prompt=Hello")!

        await manager.handle(url: url)

        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNil(manager.pendingChat)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertTrue(manager.errorMessage?.contains("type") ?? false)
    }

    @MainActor
    func testChatWithoutConfigParamsHasNoModelConfig() async {
        let url = URL(string: "ayna://chat?model=simple-model&prompt=Hello")!

        await manager.handle(url: url)

        // No config params, so no add model flow
        XCTAssertNil(manager.pendingAddModel)
        XCTAssertNotNil(manager.pendingChat)
        XCTAssertNil(manager.pendingChat?.modelConfig)
        XCTAssertEqual(manager.pendingChat?.model, "simple-model")
    }
}
