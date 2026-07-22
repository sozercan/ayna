@testable import Ayna
import Foundation

actor TestLatch {
    private var openState: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) {
        openState = open
    }

    func wait() async {
        guard !openState else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !openState else { return }
        openState = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func opened() -> Bool {
        openState
    }
}

struct ScriptedStoreHandle: Sendable { let started: TestLatch; let releaseGate: TestLatch }

actor ScriptedConversationStore: ConversationStoreAdapter {
    enum Operation: Equatable, Sendable {
        case load, save(UUID, String?), delete(UUID), clear

        func matches(_ actual: Operation) -> Bool {
            switch (self, actual) {
            case (.load, .load), (.clear, .clear): true
            case let (.save(id, title), .save(actualID, actualTitle)):
                id == actualID && (title == nil || title == actualTitle)
            case let (.delete(expected), .delete(value)): expected == value
            default: false
            }
        }
    }

    enum Outcome: Sendable { case succeed, fail, load([Conversation]), partialClear(Set<UUID>) }

    private enum Failure: Error { case scripted }

    private var persisted: [UUID: Conversation]
    private var steps: [(Operation, (Outcome, ScriptedStoreHandle))] = []
    private var recorded: [Operation] = []

    init(conversations: [Conversation] = []) {
        persisted = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    }

    func enqueue(
        _ expected: Operation,
        outcome: Outcome = .succeed,
        blocked: Bool = false
    ) -> ScriptedStoreHandle {
        let handle = ScriptedStoreHandle(started: TestLatch(), releaseGate: TestLatch(open: !blocked))
        steps.append((expected, (outcome, handle)))
        return handle
    }

    func operations() -> [Operation] {
        recorded
    }

    func persistedConversations() -> [Conversation] {
        Array(persisted.values)
    }

    func loadConversations() async throws -> [Conversation] {
        let outcome = try await next(.load)
        switch outcome {
        case .succeed: return persistedConversations()
        case let .load(values): return values
        case .fail: throw Failure.scripted
        default: throw Failure.scripted
        }
    }

    func save(_ conversation: Conversation) async throws {
        let operation = Operation.save(conversation.id, conversation.title)
        switch try await next(operation) {
        case .succeed: persisted[conversation.id] = conversation
        case .fail: throw Failure.scripted
        default: throw Failure.scripted
        }
    }

    func delete(_ id: UUID) async throws {
        let operation = Operation.delete(id)
        switch try await next(operation) {
        case .succeed: persisted.removeValue(forKey: id)
        case .fail: throw Failure.scripted
        default: throw Failure.scripted
        }
    }

    func clearConversations() async throws {
        switch try await next(.clear) {
        case .succeed: persisted.removeAll()
        case .fail: throw Failure.scripted
        case let .partialClear(ids):
            ids.forEach { persisted.removeValue(forKey: $0) }
            throw Failure.scripted
        default: throw Failure.scripted
        }
    }

    private func next(_ operation: Operation) async throws -> Outcome {
        recorded.append(operation)
        guard let index = steps.firstIndex(where: { $0.0.matches(operation) }) else { return .succeed }
        let (_, (outcome, handle)) = steps.remove(at: index)
        await handle.started.open()
        await handle.releaseGate.wait()
        return outcome
    }
}
