import os

/// Bridges one callback-driven multi-model request into structured concurrency.
struct MultiModelRequestRunner: Sendable {
    /// A GitHub Models gate acquisition paired with its explicit release.
    struct GitHubPermit: Sendable {
        private let acquireAction: @Sendable () async throws -> Void
        private let releaseAction: @Sendable () async -> Void

        init(
            acquire: @escaping @Sendable () async throws -> Void,
            release: @escaping @Sendable () async -> Void
        ) {
            acquireAction = acquire
            releaseAction = release
        }

        static func shared(
            key: String,
            onQueued: @escaping @Sendable () -> Void = {}
        ) -> GitHubPermit {
            GitHubPermit(
                acquire: {
                    try await GitHubModelsRequestGate.shared.acquire(key: key, onQueued: onQueued)
                },
                release: {
                    await GitHubModelsRequestGate.shared.release(key: key)
                }
            )
        }

        fileprivate func acquire() async throws {
            try await acquireAction()
        }

        fileprivate func release() async {
            await releaseAction()
        }
    }

    private enum ContinuationPhase {
        case pending
        case preparing(CheckedContinuation<Void, Never>)
        case invoking(CheckedContinuation<Void, Never>, terminalRequested: Bool)
        case started(CheckedContinuation<Void, Never>)
        case finished
    }

    private final class ContinuationState: Sendable {
        private let phase = OSAllocatedUnfairLock(initialState: ContinuationPhase.pending)

        func install(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            let installed = phase.withLock { phase in
                guard case .pending = phase else { return false }
                phase = .preparing(continuation)
                return true
            }

            if !installed {
                continuation.resume()
            }
            return installed
        }

        func commitStart() -> Bool {
            phase.withLock { phase in
                guard case let .preparing(continuation) = phase else { return false }
                phase = .invoking(continuation, terminalRequested: false)
                return true
            }
        }

        func startReturned() {
            let continuation = phase.withLock { phase -> CheckedContinuation<Void, Never>? in
                guard case let .invoking(continuation, terminalRequested) = phase else {
                    return nil
                }

                if terminalRequested {
                    phase = .finished
                    return continuation
                }

                phase = .started(continuation)
                return nil
            }
            continuation?.resume()
        }

        var isFinished: Bool {
            phase.withLock { phase in
                switch phase {
                case let .invoking(_, terminalRequested):
                    terminalRequested
                case .finished:
                    true
                case .pending, .preparing, .started:
                    false
                }
            }
        }

        @discardableResult
        func finish() -> Bool {
            let result = phase.withLock { phase -> (didFinish: Bool, continuation: CheckedContinuation<Void, Never>?) in
                switch phase {
                case .pending:
                    phase = .finished
                    return (true, nil)
                case let .preparing(continuation):
                    phase = .finished
                    return (true, continuation)
                case let .invoking(continuation, terminalRequested):
                    guard !terminalRequested else { return (false, nil) }
                    phase = .invoking(continuation, terminalRequested: true)
                    return (true, nil)
                case let .started(continuation):
                    phase = .finished
                    return (true, continuation)
                case .finished:
                    return (false, nil)
                }
            }
            result.continuation?.resume()
            return result.didFinish
        }
    }

    /// Idempotent completion handle that may be called from any callback thread.
    final class Completion: Sendable {
        private let state = ContinuationState()

        fileprivate init() {}

        @discardableResult
        func callAsFunction() -> Bool {
            state.finish()
        }

        var isFinished: Bool {
            state.isFinished
        }

        fileprivate func install(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            state.install(continuation)
        }

        fileprivate func commitStart() -> Bool {
            state.commitStart()
        }

        fileprivate func startReturned() {
            state.startReturned()
        }

        fileprivate func cancel() {
            state.finish()
        }
    }

    /// Acquires an optional GitHub permit, synchronously commits `start` on the
    /// main actor, then waits for either callback completion or cancellation.
    @MainActor
    static func run(
        gitHubPermit: GitHubPermit? = nil,
        start: @escaping @MainActor @Sendable (Completion) -> Void
    ) async {
        guard !Task.isCancelled else { return }

        if let gitHubPermit {
            do {
                try await gitHubPermit.acquire()
            } catch {
                return
            }

            guard !Task.isCancelled else {
                await gitHubPermit.release()
                return
            }

            await waitForCompletion(start: start)
            await gitHubPermit.release()
            return
        }

        await waitForCompletion(start: start)
    }

    @MainActor
    private static func waitForCompletion(
        start: @escaping @MainActor @Sendable (Completion) -> Void
    ) async {
        let completion = Completion()

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard completion.install(continuation),
                      completion.commitStart()
                else {
                    return
                }
                start(completion)
                completion.startReturned()
            }
        } onCancel: {
            completion.cancel()
        }
    }
}
