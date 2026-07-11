@testable import Ayna
import Foundation
import Testing

@Suite("ConversationPersistenceCoordinator Tests", .tags(.persistence, .async), .serialized)
@MainActor
struct ConversationPersistenceCoordinatorTests {
    enum InitialIntent: CaseIterable, Sendable { case save, delete, clear }

    @Test("Repeated coalesced saves write only the latest value")
    func repeatedSavesCoalesce() async {
        let id = UUID(), first = conversation(id: id, title: "First"), latest = conversation(id: id, title: "Latest")
        let store = ScriptedConversationStore()
        let coordinator = makeCoordinator(store)
        coordinator.apply(first)
        coordinator.apply(latest)
        await coordinator.flush().value
        #expect(await store.operations() == [.save(latest.id, latest.title)])
        #expect(await store.persistedConversations() == [latest])
    }

    @Test("Immediate save receipt does not activate another conversation's debounce")
    func immediateSaveReceiptIsTargetScoped() async {
        let queued = conversation(title: "Queued"), immediate = conversation(title: "Immediate")
        let store = ScriptedConversationStore()
        let gate = await store.enqueue(.save(immediate.id, nil), blocked: true)
        let coordinator = makeCoordinator(store)
        coordinator.apply(queued)
        guard let receipt = coordinator.apply(immediate, mode: .immediate) else {
            Issue.record("Missing immediate receipt")
            return
        }
        await gate.started.wait()
        await gate.releaseGate.open()
        await receipt.value
        #expect(await store.operations() == [.save(immediate.id, immediate.title)])
        await coordinator.flush().value
        #expect(await store.operations() == [.save(immediate.id, immediate.title), .save(queued.id, queued.title)])
    }

    @Test("Queued save followed by delete never writes the queued save")
    func queuedSaveThenDelete() async {
        let value = conversation(title: "Queued")
        let store = ScriptedConversationStore(conversations: [value])
        let coordinator = makeCoordinator(store)
        coordinator.apply(value)
        #expect(await coordinator.delete(value).value == .deleted)
        await coordinator.flush().value
        #expect(await store.operations() == [.delete(value.id)])
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test("In-flight save is physically followed by delete")
    func inFlightSaveThenDelete() async {
        let value = conversation(title: "Saving")
        let store = ScriptedConversationStore()
        let gate = await store.enqueue(.save(value.id, nil), blocked: true)
        let coordinator = makeCoordinator(store)
        coordinator.apply(value, mode: .immediate)
        await gate.started.wait()
        let deletion = coordinator.delete(value)
        #expect(await store.operations() == [.save(value.id, value.title)])
        await gate.releaseGate.open()
        #expect(await deletion.value == .deleted)
        #expect(await store.operations() == [.save(value.id, value.title), .delete(value.id)])
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test("Stale save completion cannot settle an immediate newer save")
    func staleSaveThenImmediateNewerSave() async {
        let id = UUID(), old = conversation(id: id, title: "Older"), new = conversation(id: id, title: "Newer")
        let store = ScriptedConversationStore()
        let gate = await store.enqueue(.save(id, "Older"), blocked: true)
        let coordinator = makeCoordinator(store)
        coordinator.apply(old, mode: .immediate)
        await gate.started.wait()
        coordinator.apply(new, mode: .immediate)
        await gate.releaseGate.open()
        await coordinator.flush().value
        #expect(await store.operations() == [.save(old.id, old.title), .save(new.id, new.title)])
        #expect(await store.persistedConversations() == [new])
    }

    @Test("Clear follows an in-flight save and prevents resurrection")
    func clearWithInFlightSave() async {
        let value = conversation(title: "In flight")
        let store = ScriptedConversationStore()
        let gate = await store.enqueue(.save(value.id, nil), blocked: true)
        let coordinator = makeCoordinator(store)
        coordinator.apply(value, mode: .immediate)
        await gate.started.wait()
        let clearing = coordinator.clear([value])
        await gate.releaseGate.open()
        #expect(await clearing.value == .cleared)
        #expect(await store.operations() == [.save(value.id, value.title), .clear])
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test("Save, delete, and clear registered during initial load reconcile internally", arguments: InitialIntent.allCases)
    func intentWhileInitialLoadBlocked(_ intent: InitialIntent) async {
        let disk = conversation(title: "Disk"), created = conversation(title: "Created")
        let store = ScriptedConversationStore(conversations: [disk])
        let gate = await store.enqueue(.load, outcome: .load([disk]), blocked: true)
        let coordinator = makeCoordinator(store)
        let loading = coordinator.load()
        await gate.started.wait()

        switch intent {
        case .save:
            coordinator.apply(created, mode: .immediate)
            await gate.releaseGate.open()
            #expect(await loading.value == .loaded([created, disk]))
            await coordinator.flush().value
            #expect(await Set(store.persistedConversations().map(\.id)) == Set([disk.id, created.id]))
        case .delete:
            let deletion = coordinator.delete(disk)
            await gate.releaseGate.open()
            #expect(await loading.value == .loaded([]))
            #expect(await deletion.value == .deleted)
        case .clear:
            let clearing = coordinator.clear([])
            await gate.releaseGate.open()
            #expect(await loading.value == .superseded)
            #expect(await clearing.value == .cleared)
        }
    }

    @Test("Older reload result is suppressed after a newer reload is registered")
    func olderReloadCannotOverwriteNewerReload() async {
        let old = conversation(title: "Older"), new = conversation(title: "Newer")
        let store = ScriptedConversationStore()
        let oldGate = await store.enqueue(.load, outcome: .load([old]), blocked: true)
        let newGate = await store.enqueue(.load, outcome: .load([new]), blocked: true)
        let coordinator = ConversationPersistenceCoordinator(store: store)
        let oldLoad = coordinator.load()
        await oldGate.started.wait()
        let newLoad = coordinator.load()
        await oldGate.releaseGate.open()
        #expect(await oldLoad.value == .superseded)
        await newGate.started.wait()
        await newGate.releaseGate.open()
        #expect(await newLoad.value == .loaded([new]))
    }

    @Test("Flush waits for an in-flight immediate save")
    func flushWaitsForInFlightImmediateSave() async {
        let value = conversation(title: "Immediate")
        let store = ScriptedConversationStore()
        let gate = await store.enqueue(.save(value.id, nil), blocked: true)
        let coordinator = ConversationPersistenceCoordinator(store: store)
        coordinator.apply(value, mode: .immediate)
        await gate.started.wait()
        let started = TestLatch(), finished = TestLatch()
        let waiter = signal(coordinator.flush(), started: started, finished: finished)
        await started.wait()
        #expect(await finished.opened() == false)
        await gate.releaseGate.open()
        await waiter.value
        #expect(await store.persistedConversations() == [value])
    }

    @Test("Failed partial clear preserves post-clear creation and delete, then reconverges storage")
    func failedClearPreservesPostClearChangesAndConverges() async {
        let before = conversation(title: "Before"), deleted = conversation(title: "Deleted after clear")
        let created = conversation(title: "Created after clear")
        let store = ScriptedConversationStore(conversations: [before, deleted])
        let gate = await store.enqueue(.clear, outcome: .partialClear([before.id]), blocked: true)
        let coordinator = makeCoordinator(store)
        let clearing = coordinator.clear([before, deleted])
        await gate.started.wait()
        coordinator.apply(created, mode: .immediate)
        let deletion = coordinator.delete(deleted)
        await gate.releaseGate.open()
        guard case let .failed(restored, _) = await clearing.value else {
            Issue.record("Expected clear failure")
            return
        }
        #expect(Set(restored.map(\.id)) == Set([before.id, created.id]))
        #expect(await deletion.value == .deleted)
        await coordinator.flush().value
        #expect(await Set(store.persistedConversations().map(\.id)) == Set([before.id, created.id]))
    }

    @Test("Failed delete restores, re-persists, and is drained by an earlier flush")
    func failedDeleteRestoresAndRepersistsUndeliveredEdit() async {
        let id = UUID(), stored = conversation(id: id, title: "Stored"), edited = conversation(id: id, title: "Edited")
        let store = ScriptedConversationStore(conversations: [stored])
        let deleteGate = await store.enqueue(.delete(id), outcome: .fail, blocked: true)
        let repairGate = await store.enqueue(.save(id, nil), blocked: true)
        let coordinator = makeCoordinator(store)
        coordinator.apply(edited)
        let deletion = coordinator.delete(edited)
        await deleteGate.started.wait()
        let started = TestLatch(), finished = TestLatch()
        let waiter = signal(coordinator.flush(), started: started, finished: finished)
        await started.wait()
        await deleteGate.releaseGate.open()
        await repairGate.started.wait()
        #expect(await finished.opened() == false)
        guard case let .failed(restored, _) = await deletion.value else {
            Issue.record("Expected delete failure")
            return
        }
        #expect(restored == edited)
        await repairGate.releaseGate.open()
        await waiter.value
        #expect(await store.persistedConversations() == [edited])
    }

    @Test("Failed save remains dirty across reload and is retried by flush")
    func failedSaveStaysDirtyAcrossReload() async {
        let id = UUID(), stored = conversation(id: id, title: "Stored"), edited = conversation(id: id, title: "Edited")
        let store = ScriptedConversationStore(conversations: [stored])
        _ = await store.enqueue(.save(id, nil), outcome: .fail)
        _ = await store.enqueue(.load, outcome: .load([stored]))
        let coordinator = ConversationPersistenceCoordinator(store: store)
        coordinator.apply(edited, mode: .immediate)
        await coordinator.flush().value
        #expect(await coordinator.load().value == .loaded([edited]))
        await coordinator.flush().value
        #expect(await store.persistedConversations() == [edited])
    }

    @Test("Cancelling a receipt waiter does not cancel accepted persistence")
    func waiterCancellationDoesNotCancelPersistence() async {
        let value = conversation(title: "Delete me")
        let store = ScriptedConversationStore(conversations: [value])
        let gate = await store.enqueue(.delete(value.id), blocked: true)
        let coordinator = ConversationPersistenceCoordinator(store: store)
        let receipt = coordinator.delete(value)
        await gate.started.wait()
        let waiter = Task { await receipt.value }
        waiter.cancel()
        await gate.releaseGate.open()
        await coordinator.flush().value
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test("Flush drains clear repair and retains a suppressed preceding load for rollback")
    func flushDrainsClearRepairAndRetainsLoad() async {
        let disk = conversation(title: "Disk")
        let store = ScriptedConversationStore(conversations: [disk])
        let loadGate = await store.enqueue(.load, outcome: .load([disk]), blocked: true)
        _ = await store.enqueue(.clear, outcome: .fail)
        let repairGate = await store.enqueue(.clear, blocked: true)
        let coordinator = ConversationPersistenceCoordinator(store: store)
        let loading = coordinator.load()
        await loadGate.started.wait()
        let clearing = coordinator.clear([])
        let started = TestLatch(), finished = TestLatch()
        let waiter = signal(coordinator.flush(), started: started, finished: finished)
        await started.wait()
        await loadGate.releaseGate.open()
        #expect(await loading.value == .superseded)
        guard case let .failed(restored, _) = await clearing.value else {
            Issue.record("Expected clear failure")
            return
        }
        #expect(restored == [disk])
        await repairGate.started.wait()
        #expect(await finished.opened() == false)
        await repairGate.releaseGate.open()
        await waiter.value
        #expect(await store.persistedConversations() == [disk])
    }

    @Test("Rewrite completion does not supersede its queued explicit delete")
    func rewriteDoesNotSupersedeQueuedDelete() async {
        let value = conversation(title: "Delete")
        let store = ScriptedConversationStore(conversations: [value])
        _ = await store.enqueue(.clear, outcome: .fail)
        _ = await store.enqueue(.clear, outcome: .fail)
        _ = await store.enqueue(.clear)
        let coordinator = ConversationPersistenceCoordinator(store: store)
        guard case .failed = await coordinator.clear([value]).value else {
            Issue.record("Expected clear failure")
            return
        }
        await coordinator.flush().value
        #expect(await coordinator.delete(value).value == .deleted)
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test("Overlapping failed clears retain the original rollback baseline")
    func overlappingFailedClearsRetainOriginalBaseline() async {
        let original = conversation(title: "Original")
        let store = ScriptedConversationStore()
        let firstGate = await store.enqueue(.clear, outcome: .fail, blocked: true)
        _ = await store.enqueue(.clear, outcome: .fail)
        let coordinator = ConversationPersistenceCoordinator(store: store)

        let first = coordinator.clear([original])
        await firstGate.started.wait()
        let second = coordinator.clear([])
        await firstGate.releaseGate.open()

        #expect(await first.value == .superseded)
        guard case let .failed(restored, _) = await second.value else {
            Issue.record("Expected second clear failure")
            return
        }
        #expect(restored == [original])
        await coordinator.flush().value
        #expect(collectionCount(named: "clearLayers", in: Mirror(reflecting: coordinator)) == 0)
    }

    @Test("Second failed clear retains snapshot restored before first receipt consumption")
    func secondFailedClearRetainsRestoredUnsavedEdit() async {
        let id = UUID()
        let stored = conversation(id: id, title: "Stored")
        let edited = conversation(id: id, title: "Edited")
        let store = ScriptedConversationStore(conversations: [stored])
        _ = await store.enqueue(.clear, outcome: .fail)
        let repairGate = await store.enqueue(.clear, blocked: true)
        _ = await store.enqueue(.clear, outcome: .fail)
        let coordinator = makeCoordinator(store)

        #expect(await coordinator.load().value == .loaded([stored]))
        coordinator.apply(edited)
        let first = coordinator.clear([edited])
        await repairGate.started.wait()
        let second = coordinator.clear([])
        await repairGate.releaseGate.open()

        #expect(await first.value == .superseded)
        guard case let .failed(restored, _) = await second.value else {
            Issue.record("Expected second clear failure")
            return
        }
        #expect(restored == [edited])
        await coordinator.flush().value
        #expect(await store.persistedConversations() == [edited])
    }

    @Test("Failed clear tombstone survives failed rewrite and later failed clear")
    func failedClearTombstoneSurvivesUntilRewriteSuccess() async {
        let kept = conversation(title: "Kept")
        let deleted = conversation(title: "Deleted")
        let store = ScriptedConversationStore(conversations: [kept, deleted])
        let deleteGate = await store.enqueue(.delete(deleted.id), outcome: .fail, blocked: true)
        _ = await store.enqueue(.clear, outcome: .fail)
        _ = await store.enqueue(.clear, outcome: .fail)
        _ = await store.enqueue(.clear, outcome: .fail)
        let coordinator = makeCoordinator(store)

        guard case let .loaded(loaded) = await coordinator.load().value else {
            Issue.record("Expected initial load")
            return
        }
        #expect(Set(loaded.map(\.id)) == Set([kept.id, deleted.id]))
        let deleting = coordinator.delete(deleted)
        await deleteGate.started.wait()
        let firstClear = coordinator.clear([kept])
        await deleteGate.releaseGate.open()
        #expect(await deleting.value == .superseded)
        guard case let .failed(firstRollback, _) = await firstClear.value else {
            Issue.record("Expected first clear failure")
            return
        }
        #expect(firstRollback == [kept])
        await coordinator.flush().value

        let secondClear = coordinator.clear([])
        guard case let .failed(secondRollback, _) = await secondClear.value else {
            Issue.record("Expected second clear failure")
            return
        }
        #expect(secondRollback == [kept])
        await coordinator.flush().value
        #expect(await store.persistedConversations() == [kept])
        #expect(collectionCount(named: "repairDeletedIDs", in: Mirror(reflecting: coordinator)) == 0)
    }

    @Test("Settled load receipt reconciles an edit accepted before consumption")
    func settledLoadReceiptReconcilesNewerEdit() async {
        let id = UUID()
        let disk = conversation(id: id, title: "Disk")
        let edited = conversation(id: id, title: "Edited")
        let coordinator = ConversationPersistenceCoordinator(store: ScriptedConversationStore(conversations: [disk]))

        let loading = coordinator.load()
        await coordinator.flush().value
        coordinator.apply(edited)

        #expect(await loading.value == .loaded([edited]))
        await coordinator.flush().value
    }

    @Test("Failed clear receipt excludes a deletion accepted before consumption")
    func failedClearReceiptReconcilesLaterDelete() async {
        let value = conversation(title: "Delete after clear")
        let store = ScriptedConversationStore(conversations: [value])
        _ = await store.enqueue(.clear, outcome: .fail)
        let coordinator = ConversationPersistenceCoordinator(store: store)

        let clearing = coordinator.clear([value])
        await coordinator.flush().value
        #expect(await coordinator.delete(value).value == .deleted)

        guard case let .failed(restored, _) = await clearing.value else {
            Issue.record("Expected clear failure")
            return
        }
        #expect(restored.isEmpty)
    }

    @Test("Failed delete receipt is superseded by a newer clear before consumption")
    func failedDeleteReceiptDoesNotUndoNewerClear() async {
        let value = conversation(title: "Delete before clear")
        let store = ScriptedConversationStore(conversations: [value])
        _ = await store.enqueue(.delete(value.id), outcome: .fail)
        let coordinator = ConversationPersistenceCoordinator(store: store)

        let deletion = coordinator.delete(value)
        await coordinator.flush().value
        #expect(await coordinator.clear([]).value == .cleared)
        #expect(await deletion.value == .superseded)
    }

    @Test("Settled unique IDs leave no per-conversation auxiliary history")
    func settledUniqueIDsLeaveBoundedAuxiliaryState() async {
        let coordinator = ConversationPersistenceCoordinator(store: ScriptedConversationStore())
        for index in 0 ..< 2000 {
            let value = conversation(title: "Conversation \(index)")
            coordinator.apply(value, mode: .immediate)
            _ = coordinator.delete(value)
        }
        await coordinator.flush().value
        let mirror = Mirror(reflecting: coordinator)
        for label in ["snapshot", "dirty", "debounceTasks", "outstandingByRoot"] {
            #expect(collectionCount(named: label, in: mirror) == 0)
        }
    }

    private func makeCoordinator(_ store: ScriptedConversationStore) -> ConversationPersistenceCoordinator {
        ConversationPersistenceCoordinator(store: store, debounceDuration: .seconds(30))
    }

    private func signal(
        _ receipt: PersistenceReceipt<Void>,
        started: TestLatch,
        finished: TestLatch
    ) -> Task<Void, Never> {
        Task {
            await started.open()
            await receipt.value
            await finished.open()
        }
    }

    private func conversation(id: UUID = UUID(), title: String) -> Conversation {
        var value = Conversation(id: id, title: title, model: "test-model")
        value.createdAt = .init(timeIntervalSince1970: 0)
        value.updatedAt = .init(timeIntervalSince1970: TimeInterval(title.count))
        return value
    }

    private func collectionCount(named label: String, in mirror: Mirror) -> Int? {
        mirror.children.first { $0.label == label }.map { Mirror(reflecting: $0.value).children.count }
    }
}
