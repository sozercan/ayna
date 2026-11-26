@testable import Ayna
import Foundation
import Testing

@Suite("MemoryContextProvider Tests")
@MainActor
struct MemoryContextProviderTests {
    @Test
    func `build context returns empty when memory disabled`() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService.shared
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        provider.setMemoryEnabled(false)
        let context = provider.buildContext()

        #expect(!context.hasContent)
        #expect(context.sessionMetadata == nil)
        #expect(context.userMemory == nil)
        #expect(context.conversationSummaries == nil)
    }

    @Test
    func `build context includes user memory when enabled`() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService.shared
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        provider.setMemoryEnabled(true)
        memoryService.addFact("Prefers Swift")

        let context = provider.buildContext()

        #expect(context.hasContent)
        #expect(context.userMemory != nil)
        #expect(context.userMemory?.contains("Swift") == true)
    }

    @Test
    func `build context excludes current conversation from summaries`() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService.shared
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        provider.setMemoryEnabled(true)

        let conversation1 = TestHelpers.sampleConversation(title: "First Chat")
        let conversation2 = TestHelpers.sampleConversation(title: "Second Chat")

        summaryService.updateSummary(for: conversation1)
        summaryService.updateSummary(for: conversation2)

        let context = provider.buildContext(currentConversationId: conversation1.id)

        if let summaries = context.conversationSummaries {
            #expect(!summaries.contains("First Chat"))
            #expect(summaries.contains("Second Chat"))
        }
    }

    @Test
    func `process memory command returns nil when disabled`() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService.shared
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        provider.setMemoryEnabled(false)
        let response = provider.processMemoryCommand(in: "Remember that I like Swift")

        #expect(response == nil)
        #expect(memoryService.activeFacts().isEmpty)
    }

    @Test
    func `process memory command stores fact when enabled`() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService.shared
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        provider.setMemoryEnabled(true)

        let response = provider.processMemoryCommand(in: "Remember that I prefer dark mode")

        #expect(response != nil)
        #expect(memoryService.activeFacts().count == 1)
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
    func `memory fact count reflects service state`() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService.shared
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        #expect(provider.memoryFactCount == 0)

        memoryService.addFact("Fact 1")
        memoryService.addFact("Fact 2")

        #expect(provider.memoryFactCount == 2)
    }
}
