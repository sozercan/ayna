import Foundation

/// Serializes callback mutations on the main actor in submission order.
final class OrderedMainActorEventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tailTask: Task<Void, Never>?

    func enqueue(_ operation: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        let previousTask = tailTask
        let nextTask = Task.detached(priority: .userInitiated) {
            if let previousTask {
                await previousTask.value
            }
            await operation()
        }
        tailTask = nextTask
        lock.unlock()
    }

    func waitForAll() async {
        let task = lock.withLock { tailTask }
        await task?.value
    }
}
