#if !os(watchOS)

    import Foundation

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

        func track(_ request: AIImageRequest?, for id: OperationID) {
            guard let request else { return }
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
