//
//  UserMemoryServiceTests.swift
//  ayna
//
//  Created on 12/25/25.
//

@testable import Ayna
import Foundation
import Testing

@Suite("UserMemoryService Tests")
@MainActor
struct UserMemoryServiceTests {
    @Test
    func `load publishes only after authoritative storage succeeds`() async {
        let loadedFact = UserMemoryFact(content: "Persisted fact")
        let successGate = TestGate()
        let successStore = ScriptedUserMemoryStore(
            loadFacts: [loadedFact],
            loadPlan: .init(gate: successGate, outcome: .success)
        )
        let successCenter = NotificationCenter()
        let successNotifications = NotificationCounter(
            name: .watchSyncContextDidChange,
            center: successCenter
        )
        defer { successNotifications.stop() }
        let successful = UserMemoryService(
            store: successStore,
            notificationCenter: successCenter
        )

        let successfulLoad = Task { await successful.loadFacts() }
        #expect(await eventually { await successStore.loadAttemptCount == 1 })
        #expect(!successful.hasAuthoritativeFacts)
        #expect(successNotifications.received == 0)

        await successGate.open()
        await successfulLoad.value

        #expect(successful.isLoaded)
        #expect(successful.hasAuthoritativeFacts)
        #expect(successful.facts == [loadedFact])
        #expect(successNotifications.received == 1)

        let failureStore = ScriptedUserMemoryStore(loadPlan: .init(outcome: .failure))
        let failureCenter = NotificationCenter()
        let failureNotifications = NotificationCounter(
            name: .watchSyncContextDidChange,
            center: failureCenter
        )
        defer { failureNotifications.stop() }
        let failing = UserMemoryService(
            store: failureStore,
            notificationCenter: failureCenter
        )

        await failing.loadFacts()

        #expect(failing.isLoaded)
        #expect(!failing.hasAuthoritativeFacts)
        #expect(failing.facts.isEmpty)
        #expect(failureNotifications.received == 0)
    }

    @Test
    func `pre-load mutation preserves seeded facts when persistence initiates load`() async {
        let seededFact = UserMemoryFact(content: "Seeded fact")
        let store = ScriptedUserMemoryStore(loadFacts: [seededFact])
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .seconds(60),
            notificationCenter: center
        )

        let localFact = service.addFact("Local fact")
        await service.saveImmediately()

        #expect(await store.loadAttemptCount == 1)
        #expect(await store.saveAttemptCount == 1)
        #expect(service.isLoaded)
        #expect(service.facts == [localFact, seededFact])
        #expect(service.hasAuthoritativeFacts)
        #expect(notifications.received == 1)
        #expect(await store.saveAttempts == [[localFact, seededFact]])
        #expect(await store.persistedFacts == [localFact, seededFact])
    }

    @Test
    func `failed pre-load reconciliation never overwrites stored facts and retries safely`() async {
        let seededFact = UserMemoryFact(content: "Seeded fact")
        let store = ScriptedUserMemoryStore(
            loadFacts: [seededFact],
            loadPlans: [
                .init(outcome: .failure),
                .init(outcome: .success),
            ]
        )
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .seconds(60),
            notificationCenter: center
        )

        let firstLocalFact = service.addFact("First local fact")
        await service.saveImmediately()

        #expect(await store.loadAttemptCount == 1)
        #expect(await store.saveAttemptCount == 0)
        #expect(await store.persistedFacts == [seededFact])
        #expect(service.facts == [firstLocalFact])
        #expect(!service.hasAuthoritativeFacts)
        #expect(notifications.received == 0)

        let secondLocalFact = service.addFact("Second local fact")
        await service.saveImmediately()

        let expected = [secondLocalFact, firstLocalFact, seededFact]
        #expect(await store.loadAttemptCount == 2)
        #expect(await store.saveAttemptCount == 1)
        #expect(await store.saveAttempts == [expected])
        #expect(await store.persistedFacts == expected)
        #expect(service.facts == expected)
        #expect(service.hasAuthoritativeFacts)
        #expect(notifications.received == 1)
    }

    @Test
    func `local CRUD during initial load merges stored facts before publishing`() async {
        let persistedFact = UserMemoryFact(content: "Persisted fact")
        let deletedPersistedFact = UserMemoryFact(content: "Delete this persisted fact")
        let loadGate = TestGate()
        let saveGate = TestGate()
        let store = ScriptedUserMemoryStore(
            loadFacts: [persistedFact, deletedPersistedFact],
            loadPlan: .init(gate: loadGate),
            savePlans: [.init(gate: saveGate)]
        )
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .zero,
            notificationCenter: center
        )

        let load = Task { await service.loadFacts() }
        #expect(await eventually { await store.loadAttemptCount == 1 })

        let localFact = service.addFact("Local fact")
        service.deleteFact(deletedPersistedFact.id)

        await loadGate.open()
        await load.value

        #expect(service.isLoaded)
        #expect(service.facts == [localFact, persistedFact])
        #expect(!service.hasAuthoritativeFacts)
        #expect(notifications.received == 0)
        #expect(await eventually { await store.saveAttemptCount == 1 })
        #expect(await store.saveAttempts == [[localFact, persistedFact]])
        #expect(!service.hasAuthoritativeFacts)
        #expect(notifications.received == 0)

        await saveGate.open()
        #expect(await eventually { service.hasAuthoritativeFacts })

        #expect(service.hasAuthoritativeFacts)
        #expect(notifications.received == 1)
        #expect(await store.persistedFacts == [localFact, persistedFact])
    }

    @Test
    func `sync replacement supersedes an in-flight initial load`() async {
        let staleDiskFact = UserMemoryFact(content: "Stale disk fact")
        let syncedFact = UserMemoryFact(content: "Synced fact")
        let loadGate = TestGate()
        let saveGate = TestGate()
        let store = ScriptedUserMemoryStore(
            loadFacts: [staleDiskFact],
            loadPlan: .init(gate: loadGate),
            savePlans: [.init(gate: saveGate)]
        )
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .seconds(60),
            notificationCenter: center
        )

        let load = Task { await service.loadFacts() }
        #expect(await eventually { await store.loadAttemptCount == 1 })

        service.loadFactsFromSync([syncedFact])
        let save = Task { await service.saveImmediately() }
        #expect(await eventually { await store.saveAttemptCount == 1 })
        #expect(await store.saveAttempts == [[syncedFact]])

        await saveGate.open()
        await save.value
        await loadGate.open()
        await load.value

        #expect(service.isLoaded)
        #expect(service.facts == [syncedFact])
        #expect(service.hasAuthoritativeFacts)
        #expect(notifications.received == 1)
        #expect(await store.persistedFacts == [syncedFact])
    }

    @Test
    func `clear supersedes a blocked initial load without waiting`() async {
        let staleDiskFact = UserMemoryFact(content: "Stale disk fact")
        let loadGate = TestGate()
        let store = ScriptedUserMemoryStore(
            loadFacts: [staleDiskFact],
            loadPlan: .init(gate: loadGate)
        )
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(store: store, notificationCenter: center)

        let load = Task { await service.loadFacts() }
        #expect(await eventually { await store.loadAttemptCount == 1 })

        let clear = Task { await service.clearAllFacts() }
        #expect(await eventually { await store.clearAttemptCount == 1 })
        await clear.value

        #expect(service.isLoaded)
        #expect(service.facts.isEmpty)
        #expect(service.hasAuthoritativeFacts)
        #expect(notifications.received == 1)
        #expect(await store.persistedFacts.isEmpty)

        await loadGate.open()
        await load.value

        #expect(service.facts.isEmpty)
        #expect(service.hasAuthoritativeFacts)
        #expect(await store.persistedFacts.isEmpty)
    }

    @Test
    func `debounced local CRUD publishes only after its exact snapshot is durable`() async {
        let saveGate = TestGate()
        let store = ScriptedUserMemoryStore(
            savePlans: [.init(gate: saveGate, outcome: .success)]
        )
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .zero,
            notificationCenter: center
        )
        await service.loadFacts()
        #expect(service.hasAuthoritativeFacts)
        notifications.reset()

        service.addFact("Optimistic local fact")

        #expect(service.facts.map(\.content) == ["Optimistic local fact"])
        #expect(!service.hasAuthoritativeFacts)
        #expect(await eventually { await store.saveAttemptCount == 1 })
        #expect(notifications.received == 0)

        await saveGate.open()
        #expect(await eventually { service.hasAuthoritativeFacts })

        #expect(notifications.received == 1)
        #expect(await store.persistedFacts.map(\.content) == ["Optimistic local fact"])
    }

    @Test
    func `failed immediate save keeps optimistic facts private`() async {
        let store = ScriptedUserMemoryStore(savePlans: [.init(outcome: .failure)])
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .seconds(60),
            notificationCenter: center
        )
        await service.loadFacts()
        #expect(service.hasAuthoritativeFacts)
        notifications.reset()

        service.addFact("Optimistic local fact")
        await service.saveImmediately()

        #expect(service.facts.map(\.content) == ["Optimistic local fact"])
        #expect(!service.hasAuthoritativeFacts)
        #expect(notifications.received == 0)
        #expect(await store.saveAttemptCount == 1)
        #expect(await store.persistedFacts.isEmpty)
    }

    @Test
    func `stale saves serialize and only the latest durable generation publishes`() async {
        let firstSaveGate = TestGate()
        let secondSaveGate = TestGate()
        let store = ScriptedUserMemoryStore(savePlans: [
            .init(gate: firstSaveGate, outcome: .success),
            .init(gate: secondSaveGate, outcome: .success)
        ])
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .seconds(60),
            notificationCenter: center
        )
        await service.loadFacts()
        #expect(service.hasAuthoritativeFacts)
        notifications.reset()

        service.addFact("First generation")
        let firstSave = Task { await service.saveImmediately() }
        #expect(await eventually { await store.saveAttemptCount == 1 })

        service.addFact("Second generation")
        let secondSave = Task { await service.saveImmediately() }
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(await store.saveAttemptCount == 1)
        #expect(!service.hasAuthoritativeFacts)
        #expect(notifications.received == 0)

        await firstSaveGate.open()
        await firstSave.value
        #expect(await eventually { await store.saveAttemptCount == 2 })
        #expect(!service.hasAuthoritativeFacts)
        #expect(notifications.received == 0)

        await secondSaveGate.open()
        await secondSave.value

        #expect(service.hasAuthoritativeFacts)
        #expect(notifications.received == 1)
        #expect(await store.saveAttempts.map { $0.map(\.content) } == [
            ["First generation"],
            ["Second generation", "First generation"]
        ])
        #expect(await store.persistedFacts.map(\.content) == [
            "Second generation",
            "First generation"
        ])
    }

    @Test
    func `synced facts retry persistence without reloading stale disk state`() async {
        let syncedFact = UserMemoryFact(content: "Synced fact")
        let store = ScriptedUserMemoryStore(
            loadFacts: [UserMemoryFact(content: "Stale disk fact")],
            savePlans: [
                .init(outcome: .failure),
                .init(outcome: .success)
            ]
        )
        let center = NotificationCenter()
        let notifications = NotificationCounter(name: .watchSyncContextDidChange, center: center)
        defer { notifications.stop() }
        let service = UserMemoryService(
            store: store,
            saveDebounceDuration: .seconds(60),
            notificationCenter: center
        )

        service.loadFactsFromSync([syncedFact])
        #expect(service.facts == [syncedFact])
        #expect(!service.hasAuthoritativeFacts)

        await service.saveImmediately()
        #expect(service.facts == [syncedFact])
        #expect(!service.hasAuthoritativeFacts)
        #expect(notifications.received == 0)

        await service.loadFacts()

        #expect(await store.loadAttemptCount == 0)
        #expect(await store.saveAttemptCount == 2)
        #expect(service.facts == [syncedFact])
        #expect(service.hasAuthoritativeFacts)
        #expect(notifications.received == 1)
        #expect(await store.persistedFacts == [syncedFact])
    }

    @Test
    func `clear publishes only after encrypted clear succeeds`() async {
        let persistedFact = UserMemoryFact(content: "Persisted fact")
        let successGate = TestGate()
        let successStore = ScriptedUserMemoryStore(
            loadFacts: [persistedFact],
            clearPlans: [.init(gate: successGate, outcome: .success)]
        )
        let successCenter = NotificationCenter()
        let successNotifications = NotificationCounter(
            name: .watchSyncContextDidChange,
            center: successCenter
        )
        defer { successNotifications.stop() }
        let successful = UserMemoryService(
            store: successStore,
            notificationCenter: successCenter
        )
        await successful.loadFacts()
        successNotifications.reset()

        let successfulClear = Task { await successful.clearAllFacts() }
        #expect(await eventually { await successStore.clearAttemptCount == 1 })
        #expect(successful.facts.isEmpty)
        #expect(!successful.hasAuthoritativeFacts)
        #expect(successNotifications.received == 0)

        await successGate.open()
        await successfulClear.value

        #expect(successful.hasAuthoritativeFacts)
        #expect(successNotifications.received == 1)
        #expect(await successStore.persistedFacts.isEmpty)

        let failureStore = ScriptedUserMemoryStore(
            loadFacts: [persistedFact],
            clearPlans: [.init(outcome: .failure)]
        )
        let failureCenter = NotificationCenter()
        let failureNotifications = NotificationCounter(
            name: .watchSyncContextDidChange,
            center: failureCenter
        )
        defer { failureNotifications.stop() }
        let failing = UserMemoryService(
            store: failureStore,
            notificationCenter: failureCenter
        )
        await failing.loadFacts()
        failureNotifications.reset()

        await failing.clearAllFacts()

        #expect(failing.facts.isEmpty)
        #expect(!failing.hasAuthoritativeFacts)
        #expect(failureNotifications.received == 0)
        #expect(await failureStore.persistedFacts == [persistedFact])
    }

    private func eventually(_ condition: () async -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: - Fact Management

    @Test
    func `add fact stores fact correctly`() {
        let service = UserMemoryService()
        service.addFact("I prefer Swift")

        let facts = service.activeFacts()
        #expect(facts.count == 1)
        #expect(facts.first?.content == "I prefer Swift")
        #expect(facts.first?.source == .explicit)
        #expect(facts.first?.isActive == true)
    }

    @Test
    func `add multiple facts preserves order`() {
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

    @Test
    func `delete fact removes from store`() {
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

    @Test
    func `toggle fact changes isActive status`() {
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

    @Test
    func `update fact content works correctly`() {
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

    @Test
    func `clear all facts removes all facts`() async {
        let service = UserMemoryService()
        service.addFact("Fact 1")
        service.addFact("Fact 2")
        service.addFact("Fact 3")

        await service.clearAllFacts()

        #expect(service.facts.isEmpty)
        #expect(service.activeFacts().isEmpty)
    }

    // MARK: - Context Formatting

    @Test
    func `formatted for context returns nil when empty`() {
        let service = UserMemoryService()
        #expect(service.formattedForContext(tokenBudget: 1000) == nil)
    }

    @Test
    func `formatted for context includes active facts only`() {
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

    @Test
    func `formatted for context respects token budget`() {
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

    @Test
    func `memory summary reflects fact count`() {
        let service = UserMemoryService()
        #expect(service.memorySummary == "No facts stored")

        service.addFact("Fact 1")
        #expect(service.memorySummary == "1 fact stored")

        service.addFact("Fact 2")
        #expect(service.memorySummary == "2 facts stored")
    }

    // MARK: - Command Processing

    @Test
    func `process store command adds fact`() {
        let service = UserMemoryService()
        let response = service.processCommand(.store(content: "I love coding"))

        #expect(response != nil)
        #expect(service.activeFacts().count == 1)
        #expect(service.activeFacts().first?.content == "I love coding")
    }

    @Test
    func `process remove command removes matching fact`() {
        let service = UserMemoryService()
        service.addFact("I love coding")
        #expect(service.activeFacts().count == 1)

        // "love coding" has 2/3 word overlap with "I love coding", which is >50%
        let response = service.processCommand(.remove(content: "love coding"))

        #expect(response != nil)
        #expect(service.activeFacts().isEmpty)
    }

    @Test
    func `process query command returns summary`() {
        let service = UserMemoryService()
        service.addFact("I prefer dark mode")
        service.addFact("I work as a developer")

        let response = service.processCommand(.query)

        #expect(response != nil)
        #expect(response?.contains("remember") == true)
    }

    @Test
    func `process clearAll command returns guidance`() {
        let service = UserMemoryService()
        service.addFact("Fact 1")
        service.addFact("Fact 2")

        let response = service.processCommand(.clearAll)

        #expect(response != nil)
        // clearAll doesn't actually clear - it returns guidance to use settings
        #expect(response?.contains("Settings") == true)
    }

    @Test
    func `process none command returns nil`() {
        let service = UserMemoryService()
        let response = service.processCommand(.none)
        #expect(response == nil)
    }
}

private enum ScriptedStoreError: Error {
    case requestedFailure
}

private enum ScriptedOperationOutcome: Sendable {
    case success
    case failure
}

private struct ScriptedOperationPlan: Sendable {
    let gate: TestGate?
    let outcome: ScriptedOperationOutcome

    init(
        gate: TestGate? = nil,
        outcome: ScriptedOperationOutcome = .success
    ) {
        self.gate = gate
        self.outcome = outcome
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume()
        }
    }
}

private actor ScriptedUserMemoryStore: UserMemoryStoreAdapter {
    private let loadFactsValue: [UserMemoryFact]
    private let loadPlans: [ScriptedOperationPlan]
    private let savePlans: [ScriptedOperationPlan]
    private let clearPlans: [ScriptedOperationPlan]

    private(set) var loadAttemptCount = 0
    private(set) var saveAttempts: [[UserMemoryFact]] = []
    private(set) var clearAttemptCount = 0
    private(set) var persistedFacts: [UserMemoryFact]

    var saveAttemptCount: Int {
        saveAttempts.count
    }

    init(
        loadFacts: [UserMemoryFact] = [],
        loadPlan: ScriptedOperationPlan = .init(),
        loadPlans: [ScriptedOperationPlan]? = nil,
        savePlans: [ScriptedOperationPlan] = [],
        clearPlans: [ScriptedOperationPlan] = []
    ) {
        loadFactsValue = loadFacts
        self.loadPlans = loadPlans ?? [loadPlan]
        self.savePlans = savePlans
        self.clearPlans = clearPlans
        persistedFacts = loadFacts
    }

    func loadMemory() async throws -> UserMemoryStore {
        let attempt = loadAttemptCount
        loadAttemptCount += 1
        let plan = attempt < loadPlans.count ? loadPlans[attempt] : loadPlans.last ?? .init()
        try await execute(plan)
        return UserMemoryStore(facts: loadFactsValue)
    }

    func saveMemory(_ store: UserMemoryStore) async throws {
        let attempt = saveAttempts.count
        saveAttempts.append(store.facts)
        let plan = attempt < savePlans.count ? savePlans[attempt] : .init()
        try await execute(plan)
        persistedFacts = store.facts
    }

    func clearMemory() async throws {
        let attempt = clearAttemptCount
        clearAttemptCount += 1
        let plan = attempt < clearPlans.count ? clearPlans[attempt] : .init()
        try await execute(plan)
        persistedFacts = []
    }

    private func execute(_ plan: ScriptedOperationPlan) async throws {
        if let gate = plan.gate {
            await gate.wait()
        }
        if plan.outcome == .failure {
            throw ScriptedStoreError.requestedFailure
        }
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let center: NotificationCenter
    private let lock = NSLock()
    private var notificationCount = 0
    private var observer: NSObjectProtocol?

    init(name: Notification.Name, center: NotificationCenter = .default) {
        self.center = center
        observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            lock.lock()
            notificationCount += 1
            lock.unlock()
        }
    }

    var received: Int {
        lock.lock()
        defer { lock.unlock() }
        return notificationCount
    }

    func reset() {
        lock.lock()
        notificationCount = 0
        lock.unlock()
    }

    func stop() {
        guard let observer else { return }
        center.removeObserver(observer)
        self.observer = nil
    }
}

// MARK: - MemoryCommandPattern Tests

@Suite("MemoryCommandPattern Tests")
struct MemoryCommandPatternTests {
    @Test
    func `detect store command from message`() {
        let command = MemoryCommandPattern.detect(in: "Remember that I prefer dark mode")

        if case let .store(content) = command {
            #expect(content.lowercased().contains("dark mode"))
        } else {
            Issue.record("Expected store command")
        }
    }

    @Test
    func `detect remove command from message`() {
        let command = MemoryCommandPattern.detect(in: "Forget that I like coffee")

        if case let .remove(content) = command {
            #expect(content.lowercased().contains("coffee"))
        } else {
            Issue.record("Expected remove command")
        }
    }

    @Test
    func `detect query command from message`() {
        let command = MemoryCommandPattern.detect(in: "What do you remember about me?")

        if case .query = command {
            // Success
        } else {
            Issue.record("Expected query command")
        }
    }

    @Test
    func `detect clearAll command from message`() {
        let command = MemoryCommandPattern.detect(in: "Clear my memory")

        if case .clearAll = command {
            // Success
        } else {
            Issue.record("Expected clearAll command")
        }
    }

    @Test
    func `detect none for regular message`() {
        let command = MemoryCommandPattern.detect(in: "Tell me about Swift programming")

        if case .none = command {
            // Success
        } else {
            Issue.record("Expected none command")
        }
    }

    @Test
    func `avoid false positive for 'I can't remember that'`() {
        // This should NOT trigger a store command
        let command = MemoryCommandPattern.detect(in: "I can't remember that password")

        if case .none = command {
            // Success - correctly avoided false positive
        } else {
            Issue.record("Expected none command, but got \(command)")
        }
    }

    @Test
    func `avoid false positive when 'remember that' is mid-sentence`() {
        // This should NOT trigger a store command
        let command = MemoryCommandPattern.detect(in: "Do you remember that meeting we had?")

        if case .none = command {
            // Success - correctly avoided false positive
        } else {
            Issue.record("Expected none command, but got \(command)")
        }
    }

    @Test
    func `still detect valid store command at start`() {
        let command = MemoryCommandPattern.detect(in: "Remember that I like coffee")

        if case let .store(content) = command {
            #expect(content.lowercased().contains("coffee"))
        } else {
            Issue.record("Expected store command")
        }
    }

    @Test
    func `detect store command after 'please'`() {
        let command = MemoryCommandPattern.detect(in: "Please remember that I prefer dark mode")

        if case let .store(content) = command {
            #expect(content.lowercased().contains("dark mode"))
        } else {
            Issue.record("Expected store command")
        }
    }
}
