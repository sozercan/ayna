import Foundation

@MainActor
final class ToolChainCoordinator {
    struct OperationID: Hashable, Sendable {
        private let rawValue = UUID()
    }

    private struct Cancellation {
        let cancel: @MainActor () -> Void
    }

    private struct ActiveOperation {
        let id: OperationID
        let conversationID: UUID
        var cancellations: [Cancellation] = []
    }

    private struct QueuedCallback: Sendable {
        let operationID: OperationID
        let conversationID: UUID
        let operation: @MainActor @Sendable () -> Void
    }

    private final class OrderedCallbackHandoff: @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [QueuedCallback] = []
        private var nextCallbackIndex = 0
        private var isDrainScheduled = false

        func enqueue(_ callback: QueuedCallback) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            callbacks.append(callback)
            guard !isDrainScheduled else { return false }
            isDrainScheduled = true
            return true
        }

        func dequeue() -> QueuedCallback? {
            lock.lock()
            defer { lock.unlock() }

            guard callbacks.indices.contains(nextCallbackIndex) else {
                callbacks.removeAll(keepingCapacity: true)
                nextCallbackIndex = 0
                isDrainScheduled = false
                return nil
            }

            let callback = callbacks[nextCallbackIndex]
            nextCallbackIndex += 1
            return callback
        }
    }

    private nonisolated let callbackHandoff = OrderedCallbackHandoff()
    private var activeOperation: ActiveOperation?

    var hasActiveOperation: Bool {
        activeOperation != nil
    }

    func beginOperation(conversationID: UUID) -> OperationID {
        cancelCurrentOperation()
        let id = OperationID()
        activeOperation = ActiveOperation(id: id, conversationID: conversationID)
        return id
    }

    func owns(_ id: OperationID, conversationID: UUID) -> Bool {
        activeOperation?.id == id && activeOperation?.conversationID == conversationID
    }

    func track(_ request: AITextRequest, for id: OperationID) {
        trackCancellation(for: id) {
            request.cancel()
        }
    }

    func track(_ task: Task<Void, Never>, for id: OperationID) {
        trackCancellation(for: id) {
            task.cancel()
        }
    }

    func onCancel(
        for id: OperationID,
        perform action: @escaping @MainActor () -> Void
    ) {
        trackCancellation(for: id, cancellation: action)
    }

    nonisolated func enqueueCallback(
        for id: OperationID,
        conversationID: UUID,
        operation: @escaping @MainActor @Sendable () -> Void
    ) {
        let callback = QueuedCallback(
            operationID: id,
            conversationID: conversationID,
            operation: operation
        )
        guard callbackHandoff.enqueue(callback) else { return }

        Task { @MainActor [weak self] in
            self?.drainCallbacks()
        }
    }

    nonisolated func schedule(
        for id: OperationID,
        conversationID: UUID,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        enqueueCallback(for: id, conversationID: conversationID) { [weak self] in
            guard let self else { return }
            let task = Task { @MainActor [weak self] in
                guard let self,
                      self.owns(id, conversationID: conversationID),
                      !Task.isCancelled
                else {
                    return
                }
                await operation()
            }
            self.track(task, for: id)
        }
    }

    private func drainCallbacks() {
        while let callback = callbackHandoff.dequeue() {
            guard owns(callback.operationID, conversationID: callback.conversationID) else {
                continue
            }
            callback.operation()
        }
    }

    @discardableResult
    func finishOperation(_ id: OperationID) -> Bool {
        guard activeOperation?.id == id else { return false }
        activeOperation = nil
        return true
    }

    @discardableResult
    func cancelCurrentOperation() -> Bool {
        guard let operation = activeOperation else { return false }
        activeOperation = nil
        operation.cancellations.forEach { $0.cancel() }
        return true
    }

    @discardableResult
    func cancelCurrentOperation(
        finalizing finalization: @MainActor () -> Void
    ) -> Bool {
        guard let operation = activeOperation else {
            finalization()
            return false
        }

        drainCallbacks()

        guard let currentOperation = activeOperation,
              currentOperation.id == operation.id
        else {
            return true
        }

        finalization()
        activeOperation = nil
        currentOperation.cancellations.forEach { $0.cancel() }
        return true
    }

    private func trackCancellation(
        for id: OperationID,
        cancellation: @escaping @MainActor () -> Void
    ) {
        guard var operation = activeOperation, operation.id == id else {
            cancellation()
            return
        }
        operation.cancellations.append(Cancellation(cancel: cancellation))
        activeOperation = operation
    }
}
