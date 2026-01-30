//
//  MemoryContextProviderTests.swift
//  ayna
//
//  Created on 1/29/26.
//

import Foundation
import Testing

@testable import Ayna

@Suite("MemoryContextProvider Tests")
@MainActor
struct MemoryContextProviderTests {
    // MARK: - Context Building

    @Test("Build context returns empty when memory disabled")
    func buildContextReturnsEmptyWhenDisabled() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService()
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        // Memory is disabled by default
        let context = provider.buildContext()

        #expect(!context.hasContent)
        #expect(context.sessionMetadata == nil)
        #expect(context.userMemory == nil)
        #expect(context.conversationSummaries == nil)
    }

    @Test("Build context includes user memory when enabled")
    func buildContextIncludesUserMemoryWhenEnabled() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService()
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        // Enable memory and add a fact
        provider.setMemoryEnabled(true)
        memoryService.addFact("Prefers Swift")

        let context = provider.buildContext()

        #expect(context.hasContent)
        #expect(context.userMemory != nil)
        #expect(context.userMemory?.contains("Swift") == true)
    }

    @Test("Build context excludes current conversation from summaries")
    func buildContextExcludesCurrentConversation() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService()
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        provider.setMemoryEnabled(true)

        // Add some conversation summaries
        let conversation1 = TestHelpers.sampleConversation(title: "First Chat")
        let conversation2 = TestHelpers.sampleConversation(title: "Second Chat")

        summaryService.updateSummary(for: conversation1)
        summaryService.updateSummary(for: conversation2)

        // Build context excluding conversation1
        let context = provider.buildContext(currentConversationId: conversation1.id)

        // Should only include conversation2's summary
        if let summaries = context.conversationSummaries {
            #expect(!summaries.contains("First Chat"))
            #expect(summaries.contains("Second Chat"))
        }
    }

    // MARK: - Memory Command Processing

    @Test("Process memory command returns nil when disabled")
    func processMemoryCommandReturnsNilWhenDisabled() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService()
        let summaryService = ConversationSummaryService()

        let provider = MemoryContextProvider(
            memoryService: memoryService,
            metadataService: metadataService,
            summaryService: summaryService
        )

        // Memory disabled by default
        let response = provider.processMemoryCommand(in: "Remember that I like Swift")

        #expect(response == nil)
        #expect(memoryService.activeFacts().isEmpty)
    }

    @Test("Process memory command stores fact when enabled")
    func processMemoryCommandStoresFactWhenEnabled() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService()
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

    // MARK: - Context Allocation

    @Test("Context allocation adapts to small context window")
    func contextAllocationAdaptsToSmallContextWindow() {
        let allocation = MemoryContextProvider.ContextAllocation(availableTokens: 4000)

        #expect(allocation.conversationSummary == 0) // Disabled for small context
        #expect(allocation.userMemory < 1000)
    }

    @Test("Context allocation uses full budget for large context window")
    func contextAllocationUsesFullBudgetForLargeContextWindow() {
        let allocation = MemoryContextProvider.ContextAllocation(availableTokens: 128_000)

        #expect(allocation.sessionMetadata == 200)
        #expect(allocation.userMemory == 1000)
        #expect(allocation.conversationSummary == 500)
    }

    // MARK: - Accessors

    @Test("Memory fact count reflects service state")
    func memoryFactCountReflectsServiceState() {
        let memoryService = UserMemoryService()
        let metadataService = SessionMetadataService()
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
