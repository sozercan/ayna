@testable import Ayna
import Combine
import Foundation
import Testing

@Suite("DeepLinkManager Tests", .tags(.fast))
@MainActor
struct DeepLinkManagerTests {
    init() {
        // Use in-memory keychain to avoid polluting the real Keychain during tests
        AIService.keychain = InMemoryKeychainStorage()
    }

    // MARK: - Helper

    /// Creates a fresh manager with its own AIService instance for test isolation
    private func makeManager() -> (manager: DeepLinkManager, service: AIService) {
        // Create a dedicated service instance for this test - NOT the shared singleton
        let service = AIService()
        service.customModels = []
        service.modelProviders = [:]
        service.modelEndpoints = [:]
        service.modelAPIKeys = [:]
        service.modelEndpointTypes = [:]
        let manager = DeepLinkManager(aiService: service)
        return (manager, service)
    }

    private func consumeExactlyOne(from manager: DeepLinkManager) throws -> ChatRequest {
        let requests = drainReadyChats(from: manager)
        #expect(requests.count == 1)
        return try #require(requests.first)
    }

    private func drainReadyChats(from manager: DeepLinkManager) -> [ChatRequest] {
        var requests: [ChatRequest] = []
        while let request = manager.consumeNextReadyChat() {
            requests.append(request)
        }
        return requests
    }

    private func confirmPendingModel(in manager: DeepLinkManager) throws {
        let requestID = try #require(manager.pendingAddModel?.id)
        manager.confirmAddModel(expectedRequestID: requestID)
    }

    private func cancelPendingModel(in manager: DeepLinkManager) throws {
        let requestID = try #require(manager.pendingAddModel?.id)
        manager.cancelAddModel(expectedRequestID: requestID)
    }

    // MARK: - URL Parsing Tests

    @Test("Parse add-model with all parameters")
    func parseAddModelWithAllParameters() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=gpt-4o&provider=openai&endpoint=https://api.example.com&key=sk-test&type=chat"))

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
    func parseAddModelWithMinimalParameters() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=my-model"))

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
    func parseAddModelMissingNameShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?provider=openai"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("name") ?? false)
    }

    @Test("Parse add-model empty name shows error")
    func parseAddModelEmptyNameShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name="))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
    }

    @Test("Parse add-model whitespace name shows error")
    func parseAddModelWhitespaceNameShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=%20%20%20"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage?.contains("name") == true)
    }

    @Test("Parse add-model invalid provider shows error")
    func parseAddModelInvalidProviderShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&provider=invalid-provider"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("provider") ?? false)
    }

    @Test("Parse add-model invalid endpoint type shows error")
    func parseAddModelInvalidEndpointTypeShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&type=invalid-type"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("type") ?? false)
    }

    // MARK: - Provider Parsing Tests

    @Test("Parse provider OpenAI")
    func parseProviderOpenAI() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&provider=openai"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .openai)
    }

    @Test("Parse provider GitHub")
    func parseProviderGitHub() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&provider=github"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .githubModels)
    }

    @Test("Parse provider githubmodels")
    func parseProviderGitHubModels() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&provider=githubmodels"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .githubModels)
    }

    @Test("Parse provider Apple")
    func parseProviderApple() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&provider=apple"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .appleIntelligence)
    }

    @Test("Parse provider case insensitive")
    func parseProviderCaseInsensitive() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&provider=OpenAI"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.provider == .openai)
    }

    // MARK: - Endpoint Type Parsing Tests

    @Test("Parse endpoint type chat")
    func parseEndpointTypeChat() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&type=chat"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .chatCompletions)
    }

    @Test("Parse endpoint type chatcompletions")
    func parseEndpointTypeChatCompletions() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&type=chatcompletions"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .chatCompletions)
    }

    @Test("Parse endpoint type responses")
    func parseEndpointTypeResponses() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&type=responses"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .responses)
    }

    @Test("Parse endpoint type image")
    func parseEndpointTypeImage() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&type=image"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .imageGeneration)
    }

    @Test("Parse endpoint type imagegeneration")
    func parseEndpointTypeImageGeneration() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&type=imagegeneration"))
        await manager.handle(url: url)
        #expect(manager.pendingAddModel?.endpointType == .imageGeneration)
    }

    // MARK: - Chat URL Tests

    @Test("Parse chat with all parameters")
    func parseChatWithAllParameters() async throws {
        let (manager, service) = makeManager()
        service.customModels.append("gpt-4o")
        let url = try #require(URL(string: "ayna://chat?model=gpt-4o&prompt=Hello%20world&system=You%20are%20helpful"))

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "gpt-4o")
        #expect(manager.pendingChat?.prompt == "Hello world")
        #expect(manager.pendingChat?.systemPrompt == "You are helpful")
        #expect(manager.errorMessage == nil)
    }

    @Test("Parse chat with model only")
    func parseChatWithModelOnly() async throws {
        let (manager, service) = makeManager()
        service.customModels.append("claude-3")
        let url = try #require(URL(string: "ayna://chat?model=claude-3"))

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "claude-3")
        #expect(manager.pendingChat?.prompt == nil)
        #expect(manager.pendingChat?.systemPrompt == nil)
    }

    @Test("Parse chat with prompt only")
    func parseChatWithPromptOnly() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?prompt=What%20is%20the%20weather"))

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == nil)
        #expect(manager.pendingChat?.prompt == "What is the weather")
        #expect(manager.pendingChat?.systemPrompt == nil)
    }

    @Test("Parse chat with no parameters")
    func parseChatWithNoParameters() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat"))

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == nil)
        #expect(manager.pendingChat?.prompt == nil)
        #expect(manager.pendingChat?.systemPrompt == nil)
        #expect(manager.errorMessage == nil)
    }

    // MARK: - Pending Chat Consumption Tests

    @Test("Unified chat remains pending before add-model confirmation")
    func unifiedChatRemainsPendingBeforeAddModelConfirmation() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=new-model&provider=openai&prompt=Hello"))

        await manager.handle(url: url)

        let consumedChats = drainReadyChats(from: manager)

        #expect(consumedChats.isEmpty)
        #expect(manager.pendingAddModel?.name == "new-model")
        #expect(manager.pendingChat?.model == "new-model")
        #expect(manager.pendingChat?.prompt == "Hello")
    }

    @Test("Unified chat becomes available after add-model confirmation")
    func unifiedChatBecomesAvailableAfterAddModelConfirmation() async throws {
        let (manager, service) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=new-model&provider=openai&prompt=Hello"))

        await manager.handle(url: url)
        try confirmPendingModel(in: manager)

        let consumedChat = try consumeExactlyOne(from: manager)

        #expect(service.customModels.contains("new-model"))
        #expect(consumedChat.model == "new-model")
        #expect(consumedChat.prompt == "Hello")
    }

    @Test("Consuming a ready chat clears it exactly once")
    func consumingReadyChatClearsItExactlyOnce() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?prompt=Hello"))

        await manager.handle(url: url)

        let firstConsumption = drainReadyChats(from: manager)
        let secondConsumption = drainReadyChats(from: manager)

        #expect(firstConsumption.first?.prompt == "Hello")
        #expect(manager.pendingChat == nil)
        #expect(secondConsumption.isEmpty)
    }

    @Test("Ordinary chat is immediately available for consumption")
    func ordinaryChatIsImmediatelyAvailableForConsumption() async throws {
        let (manager, service) = makeManager()
        service.customModels.append("gpt-4o")
        let url = try #require(URL(string: "ayna://chat?model=gpt-4o&prompt=Hello&system=Be%20concise"))

        await manager.handle(url: url)

        let consumedChat = try consumeExactlyOne(from: manager)

        #expect(manager.pendingAddModel == nil)
        #expect(consumedChat.model == "gpt-4o")
        #expect(consumedChat.prompt == "Hello")
        #expect(consumedChat.systemPrompt == "Be concise")
    }

    @Test("Ordinary chat is consumed before confirming an overlapping unified chat")
    func ordinaryChatIsConsumedBeforeConfirmingOverlappingUnifiedChat() async throws {
        let (manager, service) = makeManager()
        service.customModels.append("gpt-4o")
        let unifiedURL = try #require(URL(string: "ayna://chat?model=deferred-model&provider=openai&prompt=Deferred"))
        let ordinaryURL = try #require(URL(string: "ayna://chat?model=gpt-4o&prompt=Ready"))

        await manager.handle(url: unifiedURL)
        await manager.handle(url: ordinaryURL)

        let ordinaryChat = try consumeExactlyOne(from: manager)

        #expect(ordinaryChat.model == "gpt-4o")
        #expect(ordinaryChat.prompt == "Ready")
        #expect(manager.pendingAddModel?.name == "deferred-model")
        #expect(manager.pendingChat?.model == "deferred-model")
        #expect(manager.pendingChat?.prompt == "Deferred")
        #expect(drainReadyChats(from: manager).isEmpty)

        try confirmPendingModel(in: manager)

        let deferredChat = try consumeExactlyOne(from: manager)

        #expect(service.customModels.contains("deferred-model"))
        #expect(deferredChat.model == "deferred-model")
        #expect(deferredChat.prompt == "Deferred")
    }

    @Test("Ordinary chat is preserved when an overlapping unified chat arrives afterward")
    func ordinaryChatIsPreservedWhenOverlappingUnifiedChatArrivesAfterward() async throws {
        let (manager, service) = makeManager()
        service.customModels.append("gpt-4o")
        let ordinaryURL = try #require(URL(string: "ayna://chat?model=gpt-4o&prompt=Ready"))
        let unifiedURL = try #require(URL(string: "ayna://chat?model=deferred-model&provider=openai&prompt=Deferred"))

        await manager.handle(url: ordinaryURL)
        await manager.handle(url: unifiedURL)

        let ordinaryChat = try consumeExactlyOne(from: manager)

        #expect(ordinaryChat.model == "gpt-4o")
        #expect(ordinaryChat.prompt == "Ready")
        #expect(manager.pendingAddModel?.name == "deferred-model")
        #expect(manager.pendingChat?.model == "deferred-model")
        #expect(manager.pendingChat?.prompt == "Deferred")
        #expect(drainReadyChats(from: manager).isEmpty)

        try confirmPendingModel(in: manager)

        let deferredChat = try consumeExactlyOne(from: manager)

        #expect(service.customModels.contains("deferred-model"))
        #expect(deferredChat.model == "deferred-model")
        #expect(deferredChat.prompt == "Deferred")
    }

    @Test("Cancelling an overlapping unified chat preserves the ordinary chat")
    func cancellingOverlappingUnifiedChatPreservesOrdinaryChat() async throws {
        let (manager, service) = makeManager()
        let unifiedURL = try #require(URL(string: "ayna://chat?model=cancelled-model&provider=openai&prompt=Deferred"))
        let ordinaryURL = try #require(URL(string: "ayna://chat?prompt=Ready"))

        await manager.handle(url: unifiedURL)
        await manager.handle(url: ordinaryURL)

        try cancelPendingModel(in: manager)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat?.prompt == "Ready")
        #expect(!service.customModels.contains("cancelled-model"))

        let ordinaryChat = try consumeExactlyOne(from: manager)

        #expect(ordinaryChat.prompt == "Ready")
        #expect(drainReadyChats(from: manager).isEmpty)
    }

    @Test("Standalone add-model confirmation does not block an ordinary chat")
    func standaloneAddModelConfirmationDoesNotBlockOrdinaryChat() async throws {
        let (manager, _) = makeManager()
        let addModelURL = try #require(URL(string: "ayna://add-model?name=standalone-model"))
        let ordinaryURL = try #require(URL(string: "ayna://chat?prompt=Ready"))

        await manager.handle(url: addModelURL)
        await manager.handle(url: ordinaryURL)

        let ordinaryChat = try consumeExactlyOne(from: manager)

        #expect(ordinaryChat.prompt == "Ready")
        #expect(manager.pendingAddModel?.name == "standalone-model")
        #expect(manager.pendingChat == nil)
    }

    @Test("Ready chats are drained in URL arrival order")
    func readyChatsAreDrainedInURLArrivalOrder() async throws {
        let (manager, _) = makeManager()
        let firstURL = try #require(URL(string: "ayna://chat?prompt=First"))
        let secondURL = try #require(URL(string: "ayna://chat?prompt=Second"))
        let thirdURL = try #require(URL(string: "ayna://chat?prompt=Third"))

        await manager.handle(url: firstURL)
        await manager.handle(url: secondURL)
        await manager.handle(url: thirdURL)

        #expect(drainReadyChats(from: manager).map(\.prompt) == ["First", "Second", "Third"])
        #expect(drainReadyChats(from: manager).isEmpty)
    }

    @Test("Earlier ready chat stays ahead of later deferred chat")
    func earlierReadyChatStaysAheadOfLaterDeferredChat() async throws {
        let (manager, _) = makeManager()
        let readyURL = try #require(URL(string: "ayna://chat?prompt=Ready"))
        let deferredURL = try #require(URL(string: "ayna://chat?model=deferred-model&provider=openai&prompt=Deferred"))

        await manager.handle(url: readyURL)
        await manager.handle(url: deferredURL)
        try confirmPendingModel(in: manager)

        #expect(drainReadyChats(from: manager).map(\.prompt) == ["Ready", "Deferred"])
    }

    @Test("Ready chat stays ahead when older deferred chat is confirmed")
    func readyChatStaysAheadWhenOlderDeferredChatIsConfirmed() async throws {
        let (manager, _) = makeManager()
        let deferredURL = try #require(URL(string: "ayna://chat?model=deferred-model&provider=openai&prompt=Deferred"))
        let readyURL = try #require(URL(string: "ayna://chat?prompt=Ready"))

        await manager.handle(url: deferredURL)
        await manager.handle(url: readyURL)
        try confirmPendingModel(in: manager)

        #expect(drainReadyChats(from: manager).map(\.prompt) == ["Ready", "Deferred"])
    }

    @Test("Second confirmation cannot replace active confirmation")
    func secondConfirmationCannotReplaceActiveConfirmation() async throws {
        let (manager, service) = makeManager()
        let firstURL = try #require(URL(string: "ayna://chat?model=first-model&provider=openai&prompt=First"))
        let secondURL = try #require(URL(string: "ayna://chat?model=second-model&provider=openai&prompt=Second"))

        await manager.handle(url: firstURL)
        let firstRequestID = try #require(manager.pendingAddModel?.id)
        await manager.handle(url: secondURL)

        #expect(manager.errorMessage == "Another model confirmation is already in progress")
        #expect(manager.pendingAddModel?.id == firstRequestID)
        #expect(manager.pendingChat?.prompt == "First")

        manager.confirmAddModel(expectedRequestID: firstRequestID)

        let chat = try consumeExactlyOne(from: manager)
        #expect(service.customModels.contains("first-model"))
        #expect(!service.customModels.contains("second-model"))
        #expect(chat.prompt == "First")
    }

    @Test("Standalone confirmation cannot replace active unified confirmation")
    func standaloneConfirmationCannotReplaceActiveUnifiedConfirmation() async throws {
        let (manager, _) = makeManager()
        let unifiedURL = try #require(URL(string: "ayna://chat?model=first-model&provider=openai&prompt=First"))
        let addModelURL = try #require(URL(string: "ayna://add-model?name=second-model"))

        await manager.handle(url: unifiedURL)
        let firstRequestID = try #require(manager.pendingAddModel?.id)
        await manager.handle(url: addModelURL)

        #expect(manager.errorMessage == "Another model confirmation is already in progress")
        #expect(manager.pendingAddModel?.id == firstRequestID)
        #expect(manager.pendingChat?.prompt == "First")
    }

    @Test(
        "Active standalone confirmation rejects another confirmation",
        arguments: [
            "ayna://add-model?name=second-model",
            "ayna://chat?model=second-model&provider=openai&prompt=Second"
        ]
    )
    func activeStandaloneConfirmationRejectsAnotherConfirmation(incomingURLString: String) async throws {
        let (manager, _) = makeManager()
        let firstURL = try #require(URL(string: "ayna://add-model?name=first-model"))
        let incomingURL = try #require(URL(string: incomingURLString))

        await manager.handle(url: firstURL)
        let firstRequestID = try #require(manager.pendingAddModel?.id)
        await manager.handle(url: incomingURL)

        #expect(manager.errorMessage == "Another model confirmation is already in progress")
        #expect(manager.pendingAddModel?.id == firstRequestID)
        #expect(manager.pendingAddModel?.name == "first-model")
        #expect(manager.pendingChat == nil)
    }

    @Test("Stale cancellation cannot cancel a newer confirmation")
    func staleCancellationCannotCancelNewerConfirmation() async throws {
        let (manager, _) = makeManager()
        let firstURL = try #require(URL(string: "ayna://add-model?name=first-model"))
        let secondURL = try #require(URL(string: "ayna://add-model?name=second-model"))

        await manager.handle(url: firstURL)
        let firstRequestID = try #require(manager.pendingAddModel?.id)
        manager.cancelAddModel(expectedRequestID: firstRequestID)
        await manager.handle(url: secondURL)
        let secondRequestID = try #require(manager.pendingAddModel?.id)

        manager.cancelAddModel(expectedRequestID: firstRequestID)

        #expect(manager.pendingAddModel?.id == secondRequestID)
        #expect(manager.pendingAddModel?.name == "second-model")
    }

    @Test("Stale confirmation cannot confirm a newer request")
    func staleConfirmationCannotConfirmNewerRequest() async throws {
        let (manager, service) = makeManager()
        let firstURL = try #require(URL(string: "ayna://add-model?name=first-model"))
        let secondURL = try #require(URL(string: "ayna://add-model?name=second-model"))

        await manager.handle(url: firstURL)
        let firstRequestID = try #require(manager.pendingAddModel?.id)
        manager.cancelAddModel(expectedRequestID: firstRequestID)
        await manager.handle(url: secondURL)
        let secondRequestID = try #require(manager.pendingAddModel?.id)

        manager.confirmAddModel(expectedRequestID: firstRequestID)

        #expect(manager.pendingAddModel?.id == secondRequestID)
        #expect(!service.customModels.contains("second-model"))
    }

    @Test("Unknown named chat is rejected instead of falling back")
    func unknownNamedChatIsRejectedInsteadOfFallingBack() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=missing-model&prompt=Private"))

        await manager.handle(url: url)

        #expect(drainReadyChats(from: manager).isEmpty)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage == "Model 'missing-model' not found")
    }

    @Test("Whitespace model is rejected before unified confirmation")
    func whitespaceModelIsRejectedBeforeUnifiedConfirmation() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=%20%20&provider=openai&prompt=Private"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage?.contains("model") == true)
    }

    @Test("Valueless model is rejected instead of falling back")
    func valuelessModelIsRejectedInsteadOfFallingBack() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model&prompt=Private"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage?.contains("model") == true)
    }

    @Test("Chat is rejected if model disappears before consumption")
    func chatIsRejectedIfModelDisappearsBeforeConsumption() async throws {
        let (manager, service) = makeManager()
        service.customModels.append("temporary-model")
        let url = try #require(URL(string: "ayna://chat?model=temporary-model&prompt=Private"))

        await manager.handle(url: url)
        service.customModels.removeAll()

        #expect(drainReadyChats(from: manager).isEmpty)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage == "Model 'temporary-model' not found")
    }

    @Test("Cancelled deferred chat is absent when cancellation publishes")
    func cancelledDeferredChatIsAbsentWhenCancellationPublishes() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=cancel-model&provider=openai&prompt=Private"))
        await manager.handle(url: url)

        var chatVisibleWhenCancellationPublished: ChatRequest?
        let cancellation = manager.$pendingAddModel
            .dropFirst()
            .sink { request in
                if request == nil {
                    chatVisibleWhenCancellationPublished = manager.pendingChat
                }
            }

        try cancelPendingModel(in: manager)

        #expect(chatVisibleWhenCancellationPublished == nil)
        withExtendedLifetime(cancellation) {}
    }

    // MARK: - Invalid URL Tests

    @Test("Invalid scheme shows error")
    func invalidSchemeShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "https://add-model?name=test"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
    }

    @Test("Unknown action shows error")
    func unknownActionShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://unknown-action"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("Unknown action") ?? false)
    }

    // MARK: - Confirm/Cancel Tests

    @Test("Confirm add model adds model")
    func confirmAddModelAddsModel() async throws {
        let (manager, service) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test-model&provider=openai&endpoint=https://api.test.com&key=test-key"))
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)

        try confirmPendingModel(in: manager)

        #expect(manager.pendingAddModel == nil)
        #expect(service.customModels.contains("test-model"))
        #expect(service.modelProviders["test-model"] == .openai)
        #expect(service.modelEndpoints["test-model"] == "https://api.test.com")
        #expect(service.modelAPIKeys["test-model"] == "test-key")
    }

    @Test("Confirm add model without endpoint does not set endpoint")
    func confirmAddModelWithoutEndpointDoesNotSetEndpoint() async throws {
        let (manager, service) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test-model&provider=github"))
        await manager.handle(url: url)

        try confirmPendingModel(in: manager)

        #expect(service.customModels.contains("test-model"))
        #expect(service.modelEndpoints["test-model"] == nil)
    }

    @Test("Confirm add model without key does not set key")
    func confirmAddModelWithoutKeyDoesNotSetKey() async throws {
        let (manager, service) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test-model"))
        await manager.handle(url: url)

        try confirmPendingModel(in: manager)

        #expect(service.customModels.contains("test-model"))
        #expect(service.modelAPIKeys["test-model"] == nil)
    }

    @Test("Cancel add model clears pending request")
    func cancelAddModelClearsPendingRequest() async throws {
        let (manager, service) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test-model"))
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)

        try cancelPendingModel(in: manager)

        #expect(manager.pendingAddModel == nil)
        #expect(!service.customModels.contains("test-model"))
    }

    @Test("Confirm add model duplicate shows error")
    func confirmAddModelDuplicateShowsError() async throws {
        let (manager, _) = makeManager()
        // Add first model
        let url1 = try #require(URL(string: "ayna://add-model?name=duplicate-model"))
        await manager.handle(url: url1)
        try confirmPendingModel(in: manager)

        // Try to add duplicate
        let url2 = try #require(URL(string: "ayna://add-model?name=duplicate-model"))
        await manager.handle(url: url2)
        try confirmPendingModel(in: manager)

        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("already exists") ?? false)
    }

    // MARK: - Error Handling Tests

    @Test("Dismiss error clears error")
    func dismissErrorClearsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://unknown-action"))
        await manager.handle(url: url)

        #expect(manager.errorMessage != nil)

        manager.dismissError()

        #expect(manager.errorMessage == nil)
        #expect(manager.errorRecoverySuggestion == nil)
    }

    // MARK: - Main Action Tests

    @Test("Main action creates chat request")
    func mainActionCreatesChatRequest() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://main"))

        await manager.handle(url: url)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == nil)
        #expect(manager.pendingChat?.prompt == nil)
        #expect(manager.errorMessage == nil)
    }

    // MARK: - Display Property Tests

    @Test("Show add model confirmation property")
    func showAddModelConfirmationProperty() async throws {
        let (manager, _) = makeManager()
        #expect(!manager.showAddModelConfirmation)

        let url = try #require(URL(string: "ayna://add-model?name=test"))
        await manager.handle(url: url)

        #expect(manager.showAddModelConfirmation)

        try cancelPendingModel(in: manager)

        #expect(!manager.showAddModelConfirmation)
    }

    @Test("Add model request display properties")
    func addModelRequestDisplayProperties() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=test&provider=github&type=responses"))
        await manager.handle(url: url)

        #expect(manager.pendingAddModel?.displayProvider == AIProvider.githubModels.displayName)
        #expect(manager.pendingAddModel?.displayEndpointType == APIEndpointType.responses.displayName)
    }

    // MARK: - URL Encoding Tests

    @Test("URL encoded parameters are parsed correctly")
    func urlEncodedParametersAreParsedCorrectly() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?prompt=Hello%20World%21%20How%20are%20you%3F"))

        await manager.handle(url: url)

        #expect(manager.pendingChat?.prompt == "Hello World! How are you?")
    }

    @Test("Special characters in model name")
    func specialCharactersInModelName() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://add-model?name=gpt-4o-2024-05-13"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel?.name == "gpt-4o-2024-05-13")
    }

    // MARK: - Unified Add+Chat Flow Tests

    @Test("Unified flow chat with model config shows add confirmation")
    func unifiedFlowChatWithModelConfigShowsAddConfirmation() async throws {
        let (manager, _) = makeManager()
        // Model doesn't exist, should show add confirmation
        let url = try #require(URL(string: "ayna://chat?model=new-model&provider=openai&endpoint=https://api.test.com&prompt=Hello"))

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
    func unifiedFlowConfirmAddsModelAndPreservesChat() async throws {
        let (manager, service) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=unified-model&provider=github&key=test-key&prompt=Test%20prompt"))
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingChat != nil)

        try confirmPendingModel(in: manager)

        // Model should be added
        #expect(service.customModels.contains("unified-model"))
        #expect(service.modelProviders["unified-model"] == .githubModels)
        #expect(service.modelAPIKeys["unified-model"] == "test-key")

        // Add model confirmation cleared, and chat released exactly once
        #expect(manager.pendingAddModel == nil)
        let chat = try consumeExactlyOne(from: manager)
        #expect(chat.prompt == "Test prompt")
        #expect(drainReadyChats(from: manager).isEmpty)
    }

    @Test("Unified flow cancel clears both pending requests")
    func unifiedFlowCancelClearsBothPendingRequests() async throws {
        let (manager, service) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=cancel-model&provider=openai&prompt=Test"))
        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingChat != nil)

        try cancelPendingModel(in: manager)

        // Both should be cleared
        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(!service.customModels.contains("cancel-model"))
    }

    @Test("Unified flow existing model skips add confirmation")
    func unifiedFlowExistingModelSkipsAddConfirmation() async throws {
        let (manager, service) = makeManager()
        // First add a model
        service.customModels.append("existing-model")

        // Now try unified flow with same model name
        let url = try #require(URL(string: "ayna://chat?model=existing-model&provider=openai&prompt=Hello"))
        await manager.handle(url: url)

        // Should skip add confirmation since model exists
        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "existing-model")
        #expect(manager.pendingChat?.prompt == "Hello")
    }

    @Test("Unified flow with all config params")
    func unifiedFlowWithAllConfigParams() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=full-config&provider=openai&endpoint=https://api.openai.com&key=test-key&type=responses&prompt=Test&system=Be%20helpful"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel != nil)
        #expect(manager.pendingAddModel?.name == "full-config")
        #expect(manager.pendingAddModel?.provider == .openai)
        #expect(manager.pendingAddModel?.endpoint == "https://api.openai.com")
        #expect(manager.pendingAddModel?.apiKey == "test-key")
        #expect(manager.pendingAddModel?.endpointType == .responses)

        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.model == "full-config")
        #expect(manager.pendingChat?.prompt == "Test")
        #expect(manager.pendingChat?.systemPrompt == "Be helpful")
    }

    @Test("Unified flow model config is stored")
    func unifiedFlowModelConfigIsStored() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=config-test&provider=github&prompt=Hello"))

        await manager.handle(url: url)

        // Verify modelConfig is set on the chat request
        #expect(manager.pendingChat?.modelConfig != nil)
        #expect(manager.pendingChat?.modelConfig?.name == "config-test")
        #expect(manager.pendingChat?.modelConfig?.provider == .githubModels)
    }

    @Test("Unified flow invalid provider shows error")
    func unifiedFlowInvalidProviderShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=test&provider=invalid&prompt=Hello"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("provider") ?? false)
    }

    @Test("Unified flow invalid type shows error")
    func unifiedFlowInvalidTypeShowsError() async throws {
        let (manager, _) = makeManager()
        let url = try #require(URL(string: "ayna://chat?model=test&type=invalid&prompt=Hello"))

        await manager.handle(url: url)

        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat == nil)
        #expect(manager.errorMessage != nil)
        #expect(manager.errorMessage?.contains("type") ?? false)
    }

    @Test("Chat without config params has no model config")
    func chatWithoutConfigParamsHasNoModelConfig() async throws {
        let (manager, service) = makeManager()
        service.customModels.append("simple-model")
        let url = try #require(URL(string: "ayna://chat?model=simple-model&prompt=Hello"))

        await manager.handle(url: url)

        // No config params, so no add model flow
        #expect(manager.pendingAddModel == nil)
        #expect(manager.pendingChat != nil)
        #expect(manager.pendingChat?.modelConfig == nil)
        #expect(manager.pendingChat?.model == "simple-model")
    }
}
