@testable import Ayna
import Foundation
import Testing

// swiftlint:disable identifier_name
@Suite("ConversationPersistenceCoordinator Tests", .tags(.persistence, .async), .serialized)
@MainActor
// swiftlint:disable:next type_body_length
struct ConversationPersistenceCoordinatorTests {
    enum InitialIntent: CaseIterable, Sendable { case save, delete, clear }

    @Test
    func `Repeated coalesced saves write only the latest value`() async {
        let id = UUID(), first = conversation(id: id, title: "First"), latest = conversation(id: id, title: "Latest")
        let store = ScriptedConversationStore()
        let coordinator = makeCoordinator(store)
        coordinator.apply(first)
        coordinator.apply(latest)
        await coordinator.flush().value
        #expect(await store.operations() == [.save(latest.id, latest.title)])
        #expect(await store.persistedConversations() == [latest])
    }

    @Test
    func `Immediate save receipt does not activate another conversation's debounce`() async {
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
        _ = await receipt.value
        #expect(await store.operations() == [.save(immediate.id, immediate.title)])
        await coordinator.flush().value
        #expect(await store.operations() == [.save(immediate.id, immediate.title), .save(queued.id, queued.title)])
    }

    @Test
    func `Immediate save reports durable failure instead of a false acknowledgement`() async throws {
        let value = conversation(title: "Must remain pending")
        let store = ScriptedConversationStore()
        _ = await store.enqueue(.save(value.id, value.title), outcome: .fail)
        let coordinator = makeCoordinator(store)
        let receipt = try #require(coordinator.apply(value, mode: .immediate))

        let result = await receipt.value

        guard case .failed = result else {
            Issue.record("Expected an explicit save failure, got \(result)")
            return
        }
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test
    func `Successful proposed save becomes the storage snapshot`() async {
        let id = UUID()
        let stored = conversation(id: id, title: "Stored")
        let proposed = conversation(id: id, title: "Proposed")
        let store = ScriptedConversationStore(conversations: [stored])
        let coordinator = makeCoordinator(store)

        #expect(await coordinator.load().value == .loaded([stored]))
        #expect(await coordinator.saveProposed(proposed).value == .saved)
        #expect(await store.persistedConversations() == [proposed])
        #expect(await coordinator.load().value == .loaded([proposed]))
        #expect(await store.operations() == [
            .load,
            .save(proposed.id, proposed.title),
            .load,
        ])
    }

    @Test
    func `Failed proposed save automatically resumes displaced coalesced local save`() async {
        let id = UUID()
        let local = conversation(id: id, title: "Local edit")
        let proposed = conversation(id: id, title: "Proposed edit")
        let store = ScriptedConversationStore()
        _ = await store.enqueue(
            .save(proposed.id, proposed.title),
            outcome: .fail
        )
        _ = await store.enqueue(.save(local.id, local.title))
        let coordinator = makeCoordinator(store)

        coordinator.apply(local)
        let proposedResult = await coordinator.saveProposed(proposed).value

        guard case .failed = proposedResult else {
            Issue.record("Expected proposed save failure")
            return
        }
        #expect(await waitUntil {
            await store.persistedConversations() == [local]
        })
        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .save(local.id, local.title),
        ])
    }

    @Test
    func `Flush during failed proposed save drains displaced local save exactly once`() async {
        let id = UUID()
        let local = conversation(id: id, title: "Local edit")
        let proposed = conversation(id: id, title: "Proposed edit")
        let store = ScriptedConversationStore()
        let proposedGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            outcome: .fail,
            blocked: true
        )
        _ = await store.enqueue(.save(local.id, local.title))
        let coordinator = makeCoordinator(store)

        coordinator.apply(local)
        let proposedReceipt = coordinator.saveProposed(proposed)
        await proposedGate.started.wait()
        let flushReceipt = coordinator.flush()

        await proposedGate.releaseGate.open()

        guard case .failed = await proposedReceipt.value else {
            Issue.record("Expected proposed save failure")
            return
        }
        await flushReceipt.value
        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .save(local.id, local.title),
        ])
        #expect(await store.persistedConversations() == [local])
    }

    @Test
    func `Newer apply prevents failed proposed save from resuming displaced local save`() async throws {
        let id = UUID()
        let local = conversation(id: id, title: "Local edit")
        let proposed = conversation(id: id, title: "Proposed edit")
        let newer = conversation(id: id, title: "Newer edit")
        let store = ScriptedConversationStore()
        let proposedGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            outcome: .fail,
            blocked: true
        )
        _ = await store.enqueue(.save(newer.id, newer.title))
        let coordinator = makeCoordinator(store)

        coordinator.apply(local)
        let proposedReceipt = coordinator.saveProposed(proposed)
        await proposedGate.started.wait()
        let newerReceipt = try #require(coordinator.apply(newer, mode: .immediate))

        await proposedGate.releaseGate.open()

        #expect(await proposedReceipt.value == .superseded)
        #expect(await newerReceipt.value == .saved)
        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .save(newer.id, newer.title),
        ])
        #expect(await store.persistedConversations() == [newer])
    }

    @Test
    func `Newer clear prevents failed proposed save from resuming displaced local save`() async {
        let id = UUID()
        let local = conversation(id: id, title: "Local edit")
        let proposed = conversation(id: id, title: "Proposed edit")
        let store = ScriptedConversationStore()
        let proposedGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            outcome: .fail,
            blocked: true
        )
        _ = await store.enqueue(.clear)
        let coordinator = makeCoordinator(store)

        coordinator.apply(local)
        let proposedReceipt = coordinator.saveProposed(proposed)
        await proposedGate.started.wait()
        let clearReceipt = coordinator.clear([local])

        await proposedGate.releaseGate.open()

        #expect(await proposedReceipt.value == .superseded)
        #expect(await clearReceipt.value == .cleared)
        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .clear,
        ])
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test
    func `Newer apply supersedes an in-flight proposed save in physical order`() async throws {
        let id = UUID()
        let proposed = conversation(id: id, title: "Proposed")
        let newer = conversation(id: id, title: "Newer apply")
        let store = ScriptedConversationStore()
        let proposedGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            blocked: true
        )
        let coordinator = makeCoordinator(store)

        let proposedReceipt = coordinator.saveProposed(proposed)
        await proposedGate.started.wait()
        let newerReceipt = try #require(coordinator.apply(newer, mode: .immediate))

        await proposedGate.releaseGate.open()

        #expect(await proposedReceipt.value == .superseded)
        #expect(await newerReceipt.value == .saved)
        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .save(newer.id, newer.title),
        ])
        #expect(await store.persistedConversations() == [newer])
        #expect(await coordinator.load().value == .loaded([newer]))
    }

    @Test
    func `Settled proposed save receipt is superseded by newer apply before consumption`() async throws {
        let id = UUID()
        let proposed = conversation(id: id, title: "Proposed")
        let newer = conversation(id: id, title: "Newer apply")
        let store = ScriptedConversationStore()
        let coordinator = makeCoordinator(store)

        let proposedReceipt = coordinator.saveProposed(proposed)
        await coordinator.flush().value
        let newerReceipt = try #require(coordinator.apply(newer, mode: .immediate))

        #expect(await newerReceipt.value == .saved)
        #expect(await proposedReceipt.value == .superseded)
        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .save(newer.id, newer.title),
        ])
        #expect(await store.persistedConversations() == [newer])
    }

    @Test
    func `Newer delete supersedes an in-flight proposed save in physical order`() async {
        let id = UUID()
        let stored = conversation(id: id, title: "Stored")
        let proposed = conversation(id: id, title: "Proposed")
        let store = ScriptedConversationStore(conversations: [stored])
        let proposedGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            blocked: true
        )
        let coordinator = makeCoordinator(store)

        #expect(await coordinator.load().value == .loaded([stored]))
        let proposedReceipt = coordinator.saveProposed(proposed)
        await proposedGate.started.wait()
        let deleteReceipt = coordinator.delete(stored)

        await proposedGate.releaseGate.open()

        #expect(await proposedReceipt.value == .superseded)
        #expect(await deleteReceipt.value == .deleted)
        #expect(await store.operations() == [
            .load,
            .save(proposed.id, proposed.title),
            .delete(stored.id),
        ])
        #expect(await store.persistedConversations().isEmpty)
        #expect(await coordinator.load().value == .loaded([]))
    }

    @Test
    func `Failed proposal after superseding delete repairs the prior conversation`() async {
        let id = UUID()
        let stored = conversation(id: id, title: "Stored")
        let proposed = conversation(id: id, title: "Proposed")
        let store = ScriptedConversationStore(conversations: [stored])
        let deleteGate = await store.enqueue(.delete(stored.id), blocked: true)
        _ = await store.enqueue(
            .save(proposed.id, proposed.title),
            outcome: .fail
        )
        _ = await store.enqueue(.save(stored.id, stored.title))
        let coordinator = makeCoordinator(store)

        #expect(await coordinator.load().value == .loaded([stored]))
        let deleteReceipt = coordinator.delete(stored)
        await deleteGate.started.wait()
        let proposedReceipt = coordinator.saveProposed(proposed)

        await deleteGate.releaseGate.open()

        #expect(await deleteReceipt.value == .superseded)
        guard case .failed = await proposedReceipt.value else {
            Issue.record("Expected proposed save failure")
            return
        }

        await coordinator.flush().value

        #expect(await coordinator.load().value == .loaded([stored]))
        #expect(await store.persistedConversations() == [stored])
        #expect(await store.operations() == [
            .load,
            .delete(stored.id),
            .save(proposed.id, proposed.title),
            .save(stored.id, stored.title),
            .load,
        ])
    }

    @Test
    func `ID-only delete retries the physical deletion without fabricating rollback state`() async {
        let hidden = conversation(title: "Hidden backing record")
        let store = ScriptedConversationStore(conversations: [hidden])
        _ = await store.enqueue(.load, outcome: .load([]))
        _ = await store.enqueue(.delete(hidden.id), outcome: .fail)
        _ = await store.enqueue(.delete(hidden.id))
        let coordinator = makeCoordinator(store)

        #expect(await coordinator.load().value == .loaded([]))
        let deletion = coordinator.delete(id: hidden.id)
        guard case .failed(nil, _) = await deletion.value else {
            Issue.record("Expected an ID-only delete failure")
            return
        }

        #expect(await coordinator.settleCurrentState(for: hidden.id) == .deleted)
        #expect(await store.persistedConversations().isEmpty)
        #expect(await store.operations() == [
            .load,
            .delete(hidden.id),
            .delete(hidden.id),
        ])
    }

    @Test
    func `Newer clear supersedes an in-flight proposed save in physical order`() async {
        let proposed = conversation(title: "Proposed")
        let store = ScriptedConversationStore()
        let proposedGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            blocked: true
        )
        let coordinator = makeCoordinator(store)

        let proposedReceipt = coordinator.saveProposed(proposed)
        await proposedGate.started.wait()
        let clearReceipt = coordinator.clear([])

        await proposedGate.releaseGate.open()

        #expect(await proposedReceipt.value == .superseded)
        #expect(await clearReceipt.value == .cleared)
        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .clear,
        ])
        #expect(await store.persistedConversations().isEmpty)
        #expect(await coordinator.load().value == .loaded([]))
    }

    @Test
    func `Failed newer clear does not resurrect a superseded proposed save`() async {
        let proposed = conversation(title: "Proposed")
        let store = ScriptedConversationStore()
        let proposedGate = await store.enqueue(
            .save(proposed.id, proposed.title),
            blocked: true
        )
        _ = await store.enqueue(.clear, outcome: .fail)
        _ = await store.enqueue(.clear)
        let coordinator = makeCoordinator(store)

        let proposedReceipt = coordinator.saveProposed(proposed)
        await proposedGate.started.wait()
        let clearReceipt = coordinator.clear([])

        await proposedGate.releaseGate.open()

        #expect(await proposedReceipt.value == .superseded)
        guard case let .failed(restored, _) = await clearReceipt.value else {
            Issue.record("Expected clear failure")
            return
        }
        #expect(restored.isEmpty)

        await coordinator.flush().value

        #expect(await store.operations() == [
            .save(proposed.id, proposed.title),
            .clear,
            .clear,
        ])
        #expect(await store.persistedConversations().isEmpty)
        #expect(await coordinator.load().value == .loaded([]))
    }

    @Test
    func `Queued save followed by delete never writes the queued save`() async {
        let value = conversation(title: "Queued")
        let store = ScriptedConversationStore(conversations: [value])
        let coordinator = makeCoordinator(store)
        coordinator.apply(value)
        #expect(await coordinator.delete(value).value == .deleted)
        await coordinator.flush().value
        #expect(await store.operations() == [.delete(value.id)])
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test
    func `In-flight save is physically followed by delete`() async {
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

    @Test
    func `Stale save completion cannot settle an immediate newer save`() async {
        let id = UUID(), old = conversation(id: id, title: "Older"), new = conversation(id: id, title: "Newer")
        let store = ScriptedConversationStore()
        let gate = await store.enqueue(.save(id, "Older"), blocked: true)
        let coordinator = makeCoordinator(store)
        let oldReceipt = coordinator.apply(old, mode: .immediate)
        await gate.started.wait()
        let newReceipt = coordinator.apply(new, mode: .immediate)
        await gate.releaseGate.open()
        #expect(await oldReceipt?.value == .superseded)
        #expect(await newReceipt?.value == .saved)
        #expect(await coordinator.settleCurrentState(for: id) == .saved)
        await coordinator.flush().value
        #expect(await store.operations() == [.save(old.id, old.title), .save(new.id, new.title)])
        #expect(await store.persistedConversations() == [new])
    }

    @Test
    func `Blocked Watch save superseded by failed clear waits for blocked repair`() async throws {
        let value = conversation(title: "Watch mutation")
        let store = ScriptedConversationStore()
        let saveGate = await store.enqueue(.save(value.id, value.title), blocked: true)
        _ = await store.enqueue(.clear, outcome: .partialClear([value.id]))
        let repairGate = await store.enqueue(.clear, blocked: true)
        let coordinator = makeCoordinator(store)
        let saveReceipt = try #require(coordinator.apply(value, mode: .immediate))

        await saveGate.started.wait()
        let clearReceipt = coordinator.clear([])
        let settlementStarted = TestLatch()
        let settlementFinished = TestLatch()
        let settlement = Task { @MainActor in
            await settlementStarted.open()
            let result = await coordinator.settleCurrentState(for: value.id)
            await settlementFinished.open()
            return result
        }
        await settlementStarted.wait()

        await saveGate.releaseGate.open()
        await repairGate.started.wait()
        #expect(await saveReceipt.value == .superseded)
        guard case .failed = await clearReceipt.value else {
            Issue.record("Expected clear failure")
            await repairGate.releaseGate.open()
            _ = await settlement.value
            return
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(await settlementFinished.opened() == false)

        await repairGate.releaseGate.open()
        #expect(await settlement.value == .saved)
        await coordinator.flush().value
        #expect(await store.persistedConversations() == [value])
    }

    @Test
    func `Durability settlement reports repeated save failure`() async throws {
        let value = conversation(title: "Still failing")
        let store = ScriptedConversationStore()
        _ = await store.enqueue(.save(value.id, value.title), outcome: .fail)
        _ = await store.enqueue(.save(value.id, value.title), outcome: .fail)
        let coordinator = makeCoordinator(store)
        let receipt = try #require(coordinator.apply(value, mode: .immediate))

        guard case .failed = await receipt.value else {
            Issue.record("Expected initial save failure")
            return
        }
        #expect(await coordinator.settleCurrentState(for: value.id) == .failed)
    }

    @Test
    func `Clear follows an in-flight save and prevents resurrection`() async {
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

    @Test(arguments: InitialIntent.allCases)
    func `Save, delete, and clear registered during initial load reconcile internally`(_ intent: InitialIntent) async {
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

    @Test
    func `Older reload result is suppressed after a newer reload is registered`() async {
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

    @Test
    func `Superseded reload cannot replace durable snapshot when the newer reload fails`() async {
        let baseline = conversation(title: "Baseline")
        let superseded = conversation(title: "Superseded")
        let store = ScriptedConversationStore()
        _ = await store.enqueue(.load, outcome: .load([baseline]))
        let olderGate = await store.enqueue(
            .load,
            outcome: .load([superseded]),
            blocked: true
        )
        let newerGate = await store.enqueue(.load, outcome: .fail, blocked: true)
        let coordinator = ConversationPersistenceCoordinator(store: store)

        #expect(await coordinator.load().value == .loaded([baseline]))
        #expect(coordinator.durableConversations() == [baseline])

        let olderLoad = coordinator.load()
        await olderGate.started.wait()
        let newerLoad = coordinator.load()
        await olderGate.releaseGate.open()

        #expect(await olderLoad.value == .superseded)
        await newerGate.started.wait()
        await newerGate.releaseGate.open()
        guard case .failed = await newerLoad.value else {
            Issue.record("Expected newer reload failure")
            return
        }

        #expect(coordinator.durableConversations() == [baseline])
    }

    @Test
    func `Flush waits for an in-flight immediate save`() async {
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

    @Test
    func `Failed partial clear preserves post-clear creation and delete, then reconverges storage`() async {
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

    @Test
    func `Failed delete restores, re-persists, and is drained by an earlier flush`() async {
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

    @Test
    func `Failed save remains dirty across reload and is retried by flush`() async {
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

    @Test
    func `Cancelling a receipt waiter does not cancel accepted persistence`() async {
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

    @Test
    func `Flush drains clear repair and retains a suppressed preceding load for rollback`() async {
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

    @Test
    func `Rewrite completion does not supersede its queued explicit delete`() async {
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

    @Test
    func `Overlapping failed clears retain the original rollback baseline`() async {
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

    @Test
    func `Second failed clear retains snapshot restored before first receipt consumption`() async {
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

    @Test
    func `Failed clear tombstone survives failed rewrite and later failed clear`() async {
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

    @Test
    func `Settled load receipt reconciles an edit accepted before consumption`() async {
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

    @Test
    func `Failed clear receipt excludes a deletion accepted before consumption`() async {
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

    @Test
    func `Failed delete receipt is superseded by a newer clear before consumption`() async {
        let value = conversation(title: "Delete before clear")
        let store = ScriptedConversationStore(conversations: [value])
        _ = await store.enqueue(.delete(value.id), outcome: .fail)
        let coordinator = ConversationPersistenceCoordinator(store: store)

        let deletion = coordinator.delete(value)
        await coordinator.flush().value
        #expect(await coordinator.clear([]).value == .cleared)
        #expect(await deletion.value == .superseded)
    }

    @Test
    func `Settled unique IDs leave no per-conversation auxiliary history`() async {
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    private func collectionCount(named label: String, in mirror: Mirror) -> Int? {
        mirror.children.first { $0.label == label }.map { Mirror(reflecting: $0.value).children.count }
    }
}

extension ConversationPersistenceCoordinatorTests {
    @Test
    func `Flush cutoff does not wait for a newer save accepted afterward`() async throws {
        let id = UUID()
        let first = conversation(id: id, title: "Before flush")
        let newer = conversation(id: id, title: "After flush")
        let store = ScriptedConversationStore()
        let firstSave = await store.enqueue(.save(id, first.title), blocked: true)
        let newerSave = await store.enqueue(.save(id, newer.title), blocked: true)
        let coordinator = makeCoordinator(store)
        coordinator.apply(first)

        let flushStarted = TestLatch()
        let flushFinished = TestLatch()
        let flushWaiter = signal(
            coordinator.flush(),
            started: flushStarted,
            finished: flushFinished
        )
        await flushStarted.wait()
        await firstSave.started.wait()
        let newerReceipt = try #require(coordinator.apply(newer, mode: .immediate))

        await firstSave.releaseGate.open()
        await newerSave.started.wait()
        let finishedBeforeNewerSave = await waitUntil(timeout: .milliseconds(50)) {
            await flushFinished.opened()
        }
        #expect(finishedBeforeNewerSave)

        await newerSave.releaseGate.open()
        await flushWaiter.value
        #expect(await newerReceipt.value == .saved)
        #expect(await store.persistedConversations() == [newer])
    }

    @Test
    func `Current snapshot settlement waits for failed partial clear repair`() async {
        let value = conversation(title: "Restore after partial clear")
        let store = ScriptedConversationStore(conversations: [value])
        let clearGate = await store.enqueue(
            .clear,
            outcome: .partialClear([value.id]),
            blocked: true
        )
        let repairGate = await store.enqueue(.clear, blocked: true)
        let coordinator = makeCoordinator(store)
        let clearing = coordinator.clear([value])

        await clearGate.started.wait()
        await clearGate.releaseGate.open()
        guard case .failed = await clearing.value else {
            Issue.record("Expected clear failure")
            return
        }
        await repairGate.started.wait()

        let finished = TestLatch()
        let settlement = Task { @MainActor in
            let result = await coordinator.settleCurrentSnapshot(for: clearing.repairToken)
            await finished.open()
            return result
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(await finished.opened() == false)
        await repairGate.releaseGate.open()
        #expect(await settlement.value == .settled)
        #expect(await store.persistedConversations() == [value])
    }

    @Test
    func `Current snapshot settlement waits for failed delete repair`() async {
        let value = conversation(title: "Restore after delete failure")
        let store = ScriptedConversationStore(conversations: [value])
        let deleteGate = await store.enqueue(
            .delete(value.id),
            outcome: .fail,
            blocked: true
        )
        let repairGate = await store.enqueue(
            .save(value.id, value.title),
            blocked: true
        )
        let coordinator = makeCoordinator(store)
        let deletion = coordinator.delete(value)

        await deleteGate.started.wait()
        await deleteGate.releaseGate.open()
        guard case .failed = await deletion.value else {
            Issue.record("Expected delete failure")
            return
        }
        await repairGate.started.wait()

        let finished = TestLatch()
        let settlement = Task { @MainActor in
            let result = await coordinator.settleCurrentSnapshot(for: deletion.repairToken)
            await finished.open()
            return result
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(await finished.opened() == false)
        await repairGate.releaseGate.open()
        #expect(await settlement.value == .settled)
        #expect(await store.persistedConversations() == [value])
    }

    @Test
    func `Delete repair settlement follows newer save through failure and retry`() async throws {
        let id = UUID()
        let restored = conversation(id: id, title: "Rollback before edit")
        let edited = conversation(id: id, title: "Edited after rollback")
        let store = ScriptedConversationStore(conversations: [restored])
        _ = await store.enqueue(.delete(id), outcome: .fail)
        let failedRollbackSave = await store.enqueue(
            .save(id, restored.title),
            outcome: .fail,
            blocked: true
        )
        let failedEditedSave = await store.enqueue(
            .save(id, edited.title),
            outcome: .fail,
            blocked: true
        )
        let successfulRetry = await store.enqueue(
            .save(id, edited.title),
            blocked: true
        )
        let coordinator = makeCoordinator(store)
        let deletion = coordinator.delete(restored)

        guard case .failed = await deletion.value else {
            Issue.record("Expected delete failure")
            return
        }
        await failedRollbackSave.started.wait()
        let editedSave = try #require(coordinator.apply(edited, mode: .immediate))

        let firstSettlementFinished = TestLatch()
        let firstSettlement = Task { @MainActor in
            let result = await coordinator.settleCurrentSnapshot(for: deletion.repairToken)
            await firstSettlementFinished.open()
            return result
        }
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(await firstSettlementFinished.opened() == false)

        await failedRollbackSave.releaseGate.open()
        await failedEditedSave.started.wait()
        #expect(await firstSettlementFinished.opened() == false)
        await failedEditedSave.releaseGate.open()
        guard case .failed = await editedSave.value else {
            Issue.record("Expected edited save failure")
            return
        }
        #expect(await firstSettlement.value == .failed)

        let retrySettlement = Task { @MainActor in
            await coordinator.settleCurrentSnapshot(
                for: deletion.repairToken,
                retryIfNeeded: true
            )
        }
        await successfulRetry.started.wait()
        await successfulRetry.releaseGate.open()

        #expect(await retrySettlement.value == .settled)
        #expect(await store.persistedConversations() == [edited])
        #expect(await store.operations() == [
            .delete(id),
            .save(id, restored.title),
            .save(id, edited.title),
            .save(id, edited.title),
        ])
    }

    @Test
    func `Current snapshot repair retries one failed attempt at a time`() async {
        let value = conversation(title: "Retry rollback")
        let store = ScriptedConversationStore(conversations: [value])
        _ = await store.enqueue(.delete(value.id), outcome: .fail)
        _ = await store.enqueue(.save(value.id, value.title), outcome: .fail)
        _ = await store.enqueue(.save(value.id, value.title), outcome: .fail)
        _ = await store.enqueue(.save(value.id, value.title))
        let coordinator = makeCoordinator(store)
        let deletion = coordinator.delete(value)

        guard case .failed = await deletion.value else {
            Issue.record("Expected delete failure")
            return
        }
        #expect(await coordinator.settleCurrentSnapshot(for: deletion.repairToken) == .failed)
        #expect(await coordinator.settleCurrentSnapshot(
            for: deletion.repairToken,
            retryIfNeeded: true
        ) == .failed)
        #expect(await coordinator.settleCurrentSnapshot(
            for: deletion.repairToken,
            retryIfNeeded: true
        ) == .settled)
        #expect(await store.persistedConversations() == [value])
    }

    @Test
    func `Newer delete supersedes older snapshot repair settlement`() async {
        let value = conversation(title: "Delete supersession")
        let edited = conversation(id: value.id, title: "Edited before newer delete")
        let store = ScriptedConversationStore(conversations: [value])
        _ = await store.enqueue(.delete(value.id), outcome: .fail)
        let oldRepair = await store.enqueue(
            .save(value.id, value.title),
            blocked: true
        )
        let newerDelete = await store.enqueue(.delete(value.id), blocked: true)
        let coordinator = makeCoordinator(store)
        let older = coordinator.delete(value)

        guard case .failed = await older.value else {
            Issue.record("Expected older delete failure")
            return
        }
        await oldRepair.started.wait()
        let editedSave = coordinator.apply(edited, mode: .immediate)
        let newer = coordinator.delete(edited)

        #expect(await coordinator.settleCurrentSnapshot(for: older.repairToken) == .superseded)
        await oldRepair.releaseGate.open()
        await newerDelete.started.wait()
        await newerDelete.releaseGate.open()
        #expect(await editedSave?.value == .superseded)
        #expect(await newer.value == .deleted)
        #expect(await store.persistedConversations().isEmpty)
    }

    @Test
    func `Newer clear supersedes older snapshot repair settlement`() async {
        let value = conversation(title: "Clear supersession")
        let edited = conversation(id: value.id, title: "Edited before newer clear")
        let store = ScriptedConversationStore(conversations: [value])
        _ = await store.enqueue(.clear, outcome: .partialClear([value.id]))
        let oldRepair = await store.enqueue(.clear, blocked: true)
        let newerClear = await store.enqueue(.clear, blocked: true)
        let coordinator = makeCoordinator(store)
        let older = coordinator.clear([value])

        guard case .failed = await older.value else {
            Issue.record("Expected older clear failure")
            return
        }
        await oldRepair.started.wait()
        let editedSave = coordinator.apply(edited, mode: .immediate)
        let newer = coordinator.clear([edited])

        #expect(await coordinator.settleCurrentSnapshot(for: older.repairToken) == .superseded)
        await oldRepair.releaseGate.open()
        await newerClear.started.wait()
        await newerClear.releaseGate.open()
        #expect(await editedSave?.value == .superseded)
        #expect(await newer.value == .cleared)
        #expect(await store.persistedConversations().isEmpty)
    }
}

extension ConversationPersistenceCoordinatorTests {
    @Test
    func `Failed newer proposed save restores durable state from before superseded proposal`() async {
        let id = UUID()
        let stored = conversation(id: id, title: "Stored before proposals")
        let first = conversation(id: id, title: "Superseded proposal")
        let second = conversation(id: id, title: "Rejected proposal")
        let store = ScriptedConversationStore(conversations: [stored])
        let firstGate = await store.enqueue(.save(id, first.title), blocked: true)
        let secondGate = await store.enqueue(.save(id, second.title), outcome: .fail, blocked: true)
        let rollbackGate = await store.enqueue(.save(id, stored.title), blocked: true)
        let coordinator = makeCoordinator(store)

        #expect(await coordinator.load().value == .loaded([stored]))
        #expect(coordinator.durableConversations() == [stored])

        let firstReceipt = coordinator.saveProposed(first)
        await firstGate.started.wait()
        await firstGate.releaseGate.open()
        await coordinator.flush().value

        #expect(await store.persistedConversations() == [first])
        #expect(coordinator.durableConversations() == [first])

        let secondReceipt = coordinator.saveProposed(second)
        await secondGate.started.wait()
        #expect(await firstReceipt.value == .superseded)

        let secondFinished = TestLatch()
        let secondWaiter = Task { @MainActor in
            let result = await secondReceipt.value
            await secondFinished.open()
            return result
        }
        await secondGate.releaseGate.open()

        let rollbackStarted = await waitUntil(timeout: .milliseconds(100)) {
            await rollbackGate.started.opened()
        }
        #expect(rollbackStarted)
        guard rollbackStarted else {
            _ = await secondWaiter.value
            return
        }
        #expect(await secondFinished.opened() == false)
        #expect(await store.persistedConversations() == [first])
        #expect(coordinator.durableConversations() == [first])

        await rollbackGate.releaseGate.open()
        guard case .failed = await secondWaiter.value else {
            Issue.record("Expected newer proposed save failure")
            return
        }

        #expect(await store.persistedConversations() == [stored])
        #expect(coordinator.durableConversations() == [stored])
        #expect(await coordinator.load().value == .loaded([stored]))
        #expect(await store.operations() == [
            .load,
            .save(id, first.title),
            .save(id, second.title),
            .save(id, stored.title),
            .load,
        ])
    }

    @Test
    func `Failed newer normal save still publishes the superseded write that became durable`() async {
        let id = UUID()
        let stored = conversation(id: id, title: "Stored")
        let first = conversation(id: id, title: "First durable")
        let second = conversation(id: id, title: "Second rejected")
        let store = ScriptedConversationStore(conversations: [stored])
        let firstGate = await store.enqueue(.save(first.id, first.title), blocked: true)
        _ = await store.enqueue(.save(second.id, second.title), outcome: .fail)
        let coordinator = makeCoordinator(store)
        var observedDurableSnapshots: [[Conversation]] = []
        coordinator.observeDurableSnapshotChanges {
            observedDurableSnapshots.append(coordinator.durableConversations())
        }

        #expect(await coordinator.load().value == .loaded([stored]))
        let initialObservationCount = observedDurableSnapshots.count
        let firstReceipt = coordinator.apply(first, mode: .immediate)
        await firstGate.started.wait()
        let secondReceipt = coordinator.apply(second, mode: .immediate)
        await firstGate.releaseGate.open()

        #expect(await firstReceipt?.value == .superseded)
        guard case .failed = await secondReceipt?.value else {
            Issue.record("Expected newer save failure")
            return
        }

        #expect(coordinator.durableConversations() == [first])
        #expect(observedDurableSnapshots.count == initialObservationCount + 1)
        #expect(observedDurableSnapshots.last == [first])
    }

    @Test
    func `Failed proposed save publishes a displaced local write that already became durable`() async {
        let id = UUID()
        let stored = conversation(id: id, title: "Stored")
        let local = conversation(id: id, title: "Local durable")
        let proposed = conversation(id: id, title: "Rejected Watch proposal")
        let store = ScriptedConversationStore(conversations: [stored])
        let localGate = await store.enqueue(.save(local.id, local.title), blocked: true)
        _ = await store.enqueue(.save(proposed.id, proposed.title), outcome: .fail)
        let coordinator = makeCoordinator(store)
        var observedDurableSnapshots: [[Conversation]] = []
        coordinator.observeDurableSnapshotChanges {
            observedDurableSnapshots.append(coordinator.durableConversations())
        }

        #expect(await coordinator.load().value == .loaded([stored]))
        let initialObservationCount = observedDurableSnapshots.count
        let localReceipt = coordinator.apply(local, mode: .immediate)
        await localGate.started.wait()
        let proposedReceipt = coordinator.saveProposed(proposed)
        await localGate.releaseGate.open()

        #expect(await localReceipt?.value == .superseded)
        guard case .failed = await proposedReceipt.value else {
            Issue.record("Expected proposed save failure")
            return
        }

        #expect(coordinator.durableConversations() == [local])
        #expect(observedDurableSnapshots.count == initialObservationCount + 1)
        #expect(observedDurableSnapshots.last == [local])
    }
}

// swiftlint:enable identifier_name
