import Foundation

/// Tracks cancellable image requests and their preparation work for one UI surface.
@MainActor
final class ImageRequestTracker {
    private var activeRequestIds: Set<UUID> = []
    private var handles: [UUID: OpenAIImageService.RequestHandle] = [:]
    private var preparationTasks: [UUID: Task<Void, Never>] = [:]

    func begin(_ requestId: UUID) {
        activeRequestIds.insert(requestId)
    }

    func isActive(_ requestId: UUID) -> Bool {
        activeRequestIds.contains(requestId)
    }

    func register(_ handle: OpenAIImageService.RequestHandle, for requestId: UUID) {
        guard activeRequestIds.contains(requestId) else {
            handle.cancel()
            return
        }
        handles[requestId]?.cancel()
        handles[requestId] = handle
    }

    func registerPreparation(_ task: Task<Void, Never>, for requestId: UUID) {
        preparationTasks[requestId]?.cancel()
        preparationTasks[requestId] = task
    }

    func finishPreparation(_ requestId: UUID) {
        preparationTasks.removeValue(forKey: requestId)
    }

    @discardableResult
    func finish(_ requestId: UUID) -> Bool {
        guard activeRequestIds.remove(requestId) != nil else { return false }
        handles.removeValue(forKey: requestId)
        preparationTasks.removeValue(forKey: requestId)
        return true
    }

    @discardableResult
    func cancelAll() -> Set<UUID> {
        let cancelledRequestIds = activeRequestIds
        for handle in handles.values {
            handle.cancel()
        }
        for task in preparationTasks.values {
            task.cancel()
        }
        activeRequestIds.removeAll()
        handles.removeAll()
        preparationTasks.removeAll()
        return cancelledRequestIds
    }
}
