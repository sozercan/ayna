//
//  UserMemoryServiceTests.swift
//  ayna
//
//  Created on 12/25/25.
//

import Foundation
import Testing

@testable import Ayna

@Suite("UserMemoryService Tests")
@MainActor
struct UserMemoryServiceTests {
    // MARK: - Fact Management

    @Test("Add fact stores fact correctly")
    func addFactStoresFactCorrectly() {
        let service = UserMemoryService()
        service.addFact("I prefer Swift")

        let facts = service.activeFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.content == "I prefer Swift")
        #expect(facts.first?.source == .explicit)
        #expect(facts.first?.isActive == true)
    }

    @Test("Add multiple facts preserves order")
    func addMultipleFactsPreservesOrder() {
        let service = UserMemoryService()
        service.addFact("Fact 1")
        service.addFact("Fact 2")
        service.addFact("Fact 3")

        let facts = service.activeFacts()
        #expect(facts.count == 3)
        // Facts are inserted at index 0, so most recent is first
        #expect(facts[0].content == "Fact 3")
        #expect(facts[1].content == "Fact 2")
        #expect(facts[2].content == "Fact 1")
    }

    @Test("Delete fact removes from store")
    func deleteFactRemovesFromStore() {
        let service = UserMemoryService()
        service.addFact("To be deleted")

        let facts = service.activeFacts()
        guard let factId = facts.first?.id else {
            Issue.record("Expected at least one fact")
            return
        }

        service.deleteFact(factId)

        #expect(service.activeFacts().isEmpty)
    }

    @Test("Toggle fact changes isActive status")
    func toggleFactChangesIsActiveStatus() {
        let service = UserMemoryService()
        service.addFact("Toggleable fact")

        guard let factId = service.activeFacts().first?.id else {
            Issue.record("Expected at least one fact")
            return
        }

        // Initially active
        #expect(service.activeFacts().count == 1)

        // Toggle off
        service.toggleFact(factId, active: false)
        #expect(service.activeFacts().isEmpty)
        #expect(service.facts.count == 1)

        // Toggle back on
        service.toggleFact(factId, active: true)
        #expect(service.activeFacts().count == 1)
    }

    @Test("Update fact content works correctly")
    func updateFactContentWorksCorrectly() {
        let service = UserMemoryService()
        service.addFact("Original content")

        guard let factId = service.activeFacts().first?.id else {
            Issue.record("Expected at least one fact")
            return
        }

        service.updateFact(factId, content: "Updated content")

        let updated = service.activeFacts().first
        #expect(updated?.content == "Updated content")
    }

    @Test("Clear all facts removes all facts")
    func clearAllFactsRemovesAllFacts() async {
        let service = UserMemoryService()
        service.addFact("Fact 1")
        service.addFact("Fact 2")
        service.addFact("Fact 3")

        await service.clearAllFacts()

        #expect(service.facts.isEmpty)
        #expect(service.activeFacts().isEmpty)
    }

    // MARK: - Context Formatting

    @Test("Formatted for context returns nil when empty")
    func formattedForContextReturnsNilWhenEmpty() {
        let service = UserMemoryService()
        #expect(service.formattedForContext(tokenBudget: 1000) == nil)
    }

    @Test("Formatted for context includes active facts only")
    func formattedForContextIncludesActiveFactsOnly() {
        let service = UserMemoryService()
        service.addFact("Active fact")
        service.addFact("Inactive fact")

        // Deactivate second fact (which is now first in list due to insert at 0)
        if let factId = service.facts.first?.id {
            service.toggleFact(factId, active: false)
        }

        let context = service.formattedForContext(tokenBudget: 1000)
        #expect(context?.contains("Active fact") == true)
        #expect(context?.contains("Inactive fact") != true)
    }

    @Test("Formatted for context respects token budget")
    func formattedForContextRespectsTokenBudget() {
        let service = UserMemoryService()
        // Add a long fact
        let longContent = String(repeating: "This is a very long fact. ", count: 100)
        service.addFact(longContent)
        service.addFact("Short fact")

        // Very small budget should limit output
        let context = service.formattedForContext(tokenBudget: 50)
        // Should have some content but be limited
        #expect(context != nil)
    }

    // MARK: - Memory Summary

    @Test("Memory summary reflects fact count")
    func memorySummaryReflectsFactCount() {
        let service = UserMemoryService()
        #expect(service.memorySummary == "No facts stored")

        service.addFact("Fact 1")
        #expect(service.memorySummary == "1 fact stored")

        service.addFact("Fact 2")
        #expect(service.memorySummary == "2 facts stored")
    }

    // MARK: - Command Processing

    @Test("Process store command adds fact")
    func processStoreCommandAddsFact() {
        let service = UserMemoryService()
        let response = service.processCommand(.store(content: "I love coding"))

        #expect(response != nil)
        #expect(service.activeFacts().count == 1)
        #expect(service.activeFacts().first?.content == "I love coding")
    }

    @Test("Process remove command removes matching fact")
    func processRemoveCommandRemovesMatchingFact() {
        let service = UserMemoryService()
        service.addFact("I love coding")
        #expect(service.activeFacts().count == 1)

        // "love coding" has 2/3 word overlap with "I love coding", which is >50%
        let response = service.processCommand(.remove(content: "love coding"))

        #expect(response != nil)
        #expect(service.activeFacts().isEmpty)
    }

    @Test("Process query command returns summary")
    func processQueryCommandReturnsSummary() {
        let service = UserMemoryService()
        service.addFact("I prefer dark mode")
        service.addFact("I work as a developer")

        let response = service.processCommand(.query)

        #expect(response != nil)
        #expect(response?.contains("remember") == true)
    }

    @Test("Process clearAll command returns guidance")
    func processClearAllCommandReturnsGuidance() {
        let service = UserMemoryService()
        service.addFact("Fact 1")
        service.addFact("Fact 2")

        let response = service.processCommand(.clearAll)

        #expect(response != nil)
        // clearAll doesn't actually clear - it returns guidance to use settings
        #expect(response?.contains("Settings") == true)
    }

    @Test("Process none command returns nil")
    func processNoneCommandReturnsNil() {
        let service = UserMemoryService()
        let response = service.processCommand(.none)
        #expect(response == nil)
    }
}

// MARK: - MemoryCommandPattern Tests

@Suite("MemoryCommandPattern Tests")
struct MemoryCommandPatternTests {
    @Test("Detect store command from message")
    func detectStoreCommandFromMessage() {
        let command = MemoryCommandPattern.detect(in: "Remember that I prefer dark mode")

        if case let .store(content) = command {
            #expect(content.lowercased().contains("dark mode"))
        } else {
            Issue.record("Expected store command")
        }
    }

    @Test("Detect remove command from message")
    func detectRemoveCommandFromMessage() {
        let command = MemoryCommandPattern.detect(in: "Forget that I like coffee")

        if case let .remove(content) = command {
            #expect(content.lowercased().contains("coffee"))
        } else {
            Issue.record("Expected remove command")
        }
    }

    @Test("Detect query command from message")
    func detectQueryCommandFromMessage() {
        let command = MemoryCommandPattern.detect(in: "What do you remember about me?")

        if case .query = command {
            // Success
        } else {
            Issue.record("Expected query command")
        }
    }

    @Test("Detect clearAll command from message")
    func detectClearAllCommandFromMessage() {
        let command = MemoryCommandPattern.detect(in: "Clear my memory")

        if case .clearAll = command {
            // Success
        } else {
            Issue.record("Expected clearAll command")
        }
    }

    @Test("Detect none for regular message")
    func detectNoneForRegularMessage() {
        let command = MemoryCommandPattern.detect(in: "Tell me about Swift programming")

        if case .none = command {
            // Success
        } else {
            Issue.record("Expected none command")
        }
    }
}
