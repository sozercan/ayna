//
//  ImageGenerationCoordinator.swift
//  ayna
//
//  Owns every stage of the current image-generation user action.
//

#if !os(watchOS)

    import Foundation

    /// Fences and cancels the tasks and transport children belonging to one image action.
    @MainActor
    final class ImageGenerationCoordinator {
        struct OperationID: Hashable, Sendable {
            private let rawValue = UUID()
        }

        private struct Cancellation {
            let cancel: @MainActor () -> Void
        }

        private struct ActiveOperation {
            let id: OperationID
            var cancellations: [Cancellation] = []
        }

        private var activeOperation: ActiveOperation?

        var hasActiveOperation: Bool {
            activeOperation != nil
        }

        /// Starts a new logical image operation and atomically fences/cancels its predecessor.
        func beginOperation() -> OperationID {
            cancelCurrentOperation()
            let id = OperationID()
            activeOperation = ActiveOperation(id: id)
            return id
        }

        func owns(_ id: OperationID) -> Bool {
            activeOperation?.id == id
        }

        static func pendingMessageIDs(
            in responseGroup: ResponseGroup,
            candidates: [UUID]
        ) -> [UUID] {
            let streamingIDs = Set(responseGroup.responses.filter { $0.status == .streaming }.map(\.id))
            return candidates.filter { streamingIDs.contains($0) }
        }

        /// Adds one AI transport child to a single- or multi-model logical operation.
        func track(_ request: AIImageRequest?, for id: OperationID) {
            guard let request else { return }
            trackCancellation(for: id) {
                request.cancel()
            }
        }

        /// Adds an auxiliary stage such as image loading or post-processing.
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

        /// Schedules actor-isolated work from a sendable transport callback and owns the task.
        nonisolated func schedule(
            for id: OperationID,
            operation: @escaping @MainActor @Sendable () async -> Void
        ) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let task = Task { @MainActor [weak self] in
                    guard let self, self.owns(id), !Task.isCancelled else { return }
                    await operation()
                }
                self.track(task, for: id)
            }
        }

        /// Completes only the matching operation; stale completions cannot clear a replacement.
        @discardableResult
        func finishOperation(_ id: OperationID) -> Bool {
            guard owns(id) else { return false }
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

#endif
