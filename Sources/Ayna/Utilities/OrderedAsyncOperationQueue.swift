//
//  OrderedAsyncOperationQueue.swift
//  ayna
//

import Foundation

/// Serializes asynchronous side effects in submission order.
final class OrderedAsyncOperationQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tailTask: Task<Void, Never>?

    @discardableResult
    func enqueue(
        priority: TaskPriority? = nil,
        operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        lock.lock()
        let previousTask = tailTask
        let task = Task.detached(priority: priority) {
            if let previousTask {
                await previousTask.value
            }
            await operation()
        }
        tailTask = task
        lock.unlock()
        return task
    }

    func waitForAll() async {
        let task = lock.withLock { tailTask }
        await task?.value
    }
}
