@testable import Ayna
import Foundation
import Testing

@Suite("MemoryContextProvider Tests", .serialized)
@MainActor
struct MemoryContextProviderTests {
    private let suiteName: String
    private let defaults: UserDefaults

    init() {
        suiteName = "MemoryContextProviderTests-\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            fatalError("Failed to create UserDefaults suite for MemoryContextProviderTests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: suiteName)
    }

    private struct ProviderFixture {
        let provider: MemoryContextProvider
        let memoryService: UserMemoryService
        let summaryService: ConversationSummaryService
    }

    private func makeProvider() throws -> ProviderFixture {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedMemoryStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )
        let memoryService = UserMemoryService(store: store)
        let metadataService = SessionMetadataService.shared
        let summaryService = ConversationSummaryService(store: store)
        let storage = defaults
        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService,
            preferencesStorageProvider: { storage }
        )
        return ProviderFixture(
            provider: provider,
            memoryService: memoryService,
            summaryService: summaryService
        )
    }

    @Test
    func `build context returns empty when memory disabled`() throws {
        let fixture = try makeProvider()

        fixture.provider.setMemoryEnabled(false)
        let context = fixture.provider.buildContext()

        #expect(!context.hasContent)
        #expect(context.sessionMetadata == nil)
        #expect(context.userMemory == nil)
        #expect(context.conversationSummaries == nil)
    }

    @Test
    func `build context includes user memory when enabled`() throws {
        let fixture = try makeProvider()

        fixture.provider.setMemoryEnabled(true)
        fixture.memoryService.addFact("Prefers Swift")

        let context = fixture.provider.buildContext()

        #expect(context.hasContent)
        #expect(context.userMemory != nil)
        #expect(context.userMemory?.contains("Swift") == true)
    }

    @Test
    func `build context excludes current conversation from summaries`() throws {
        let fixture = try makeProvider()

        fixture.provider.setMemoryEnabled(true)

        let conversation1 = TestHelpers.sampleConversation(title: "First Chat")
        let conversation2 = TestHelpers.sampleConversation(title: "Second Chat")

        fixture.summaryService.updateSummary(for: conversation1)
        fixture.summaryService.updateSummary(for: conversation2)

        let context = fixture.provider.buildContext(currentConversationId: conversation1.id)

        let summaries = try #require(context.conversationSummaries)
        #expect(!summaries.contains("First Chat"))
        #expect(summaries.contains("Second Chat"))
    }

    @Test
    func `process memory command returns nil when disabled`() throws {
        let fixture = try makeProvider()

        fixture.provider.setMemoryEnabled(false)
        let response = fixture.provider.processMemoryCommand(in: "Remember that I like Swift")

        #expect(response == nil)
        #expect(fixture.memoryService.activeFacts().isEmpty)
    }

    @Test
    func `process memory command stores fact when enabled`() throws {
        let fixture = try makeProvider()

        fixture.provider.setMemoryEnabled(true)

        let response = fixture.provider.processMemoryCommand(in: "Remember that I prefer dark mode")

        #expect(response != nil)
        #expect(fixture.memoryService.activeFacts().count == 1)
    }

    @Test
    func `context allocation adapts to small context window`() {
        let allocation = MemoryContextProvider.ContextAllocation(availableTokens: 4000)

        #expect(allocation.conversationSummary == 0)
        #expect(allocation.userMemory < 1000)
    }

    @Test
    func `context allocation uses full budget for large context window`() {
        let allocation = MemoryContextProvider.ContextAllocation(availableTokens: 128_000)

        #expect(allocation.sessionMetadata == 200)
        #expect(allocation.userMemory == 1000)
        #expect(allocation.conversationSummary == 500)
    }

    @Test
    func `enabled memory requires an authoritative load even when unchanged`() {
        #expect(MemoryContextProvider.requiresAuthoritativeLoad(
            isEnabled: true,
            hasAuthoritativeFacts: false
        ))
        #expect(!MemoryContextProvider.requiresAuthoritativeLoad(
            isEnabled: true,
            hasAuthoritativeFacts: true
        ))
        #expect(!MemoryContextProvider.requiresAuthoritativeLoad(
            isEnabled: false,
            hasAuthoritativeFacts: false
        ))
    }

    @Test
    func `memory fact count reflects service state`() throws {
        let fixture = try makeProvider()

        #expect(fixture.provider.memoryFactCount == 0)

        fixture.memoryService.addFact("Fact 1")
        fixture.memoryService.addFact("Fact 2")

        #expect(fixture.provider.memoryFactCount == 2)
    }
}
