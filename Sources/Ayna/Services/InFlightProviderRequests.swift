//
//  InFlightProviderRequests.swift
//  ayna
//
//  Owns provider adapters for the lifetime of in-flight provider requests.
//

import Foundation
import os

/// Retains per-request provider adapters and releases/cancels them by request id.
///
/// Provider adapters are not safe to reuse as singletons while multi-model calls
/// can run multiple same-provider streams concurrently, because adapters own their
/// current stream task. This Module keeps request lifetime ownership local and
/// makes future provider registry work safer.
@MainActor
final class InFlightProviderRequests {
    private struct Request {
        let provider: any AIProviderProtocol
        let onCancel: @MainActor () -> Void
    }

    private var requestsById: [UUID: Request] = [:]

    var count: Int {
        requestsById.count
    }

    func retain(
        _ provider: any AIProviderProtocol,
        requestId: UUID = UUID(),
        onCancel: @escaping @MainActor () -> Void = {}
    ) -> InFlightProviderRequestLease {
        requestsById[requestId] = Request(provider: provider, onCancel: onCancel)
        return InFlightProviderRequestLease { [weak self] in
            self?.requestsById.removeValue(forKey: requestId)
        }
    }

    func cancelAll() {
        let requests = Array(requestsById.values)
        requestsById.removeAll()
        for request in requests {
            request.onCancel()
            request.provider.cancelRequest()
        }
    }
}

/// Coordinates exactly one terminal outcome across callbacks and task cancellation.
///
/// The continuation may be installed before or after cancellation. Either way it is
/// resumed exactly once, and a cancellation cleanup registered after cancellation
/// runs immediately.
final class ProviderRequestTerminal: @unchecked Sendable {
    private enum Status {
        case active
        case completed
        case cancelled
    }

    private struct State {
        var status: Status = .active
        var continuation: CheckedContinuation<Void, Never>?
        var cancellationAction: (@Sendable () -> Void)?
    }

    private struct CancellationOutcome {
        let action: (@Sendable () -> Void)?
        let continuation: CheckedContinuation<Void, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isFinished: Bool {
        state.withLock { $0.status != .active }
    }

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let shouldResume = state.withLock { state -> Bool in
            guard state.status == .active else { return true }
            precondition(state.continuation == nil, "Provider request continuation installed more than once")
            state.continuation = continuation
            return false
        }

        if shouldResume {
            continuation.resume()
        }
    }

    func setCancellationAction(_ action: @escaping @Sendable () -> Void) {
        let shouldRun = state.withLock { state -> Bool in
            switch state.status {
            case .active:
                if let existingAction = state.cancellationAction {
                    state.cancellationAction = {
                        existingAction()
                        action()
                    }
                } else {
                    state.cancellationAction = action
                }
                return false
            case .completed:
                return false
            case .cancelled:
                return true
            }
        }

        if shouldRun {
            action()
        }
    }

    func complete(_ action: @Sendable () -> Void) {
        let result = state.withLock { state -> (Bool, CheckedContinuation<Void, Never>?) in
            guard state.status == .active else { return (false, nil) }
            state.status = .completed
            let continuation = state.continuation
            state.continuation = nil
            state.cancellationAction = nil
            return (true, continuation)
        }

        guard result.0 else { return }
        action()
        result.1?.resume()
    }

    func cancel() {
        let result = state.withLock { state -> CancellationOutcome? in
            guard state.status == .active else { return nil }
            state.status = .cancelled
            let cancellationAction = state.cancellationAction
            let continuation = state.continuation
            state.cancellationAction = nil
            state.continuation = nil
            return CancellationOutcome(action: cancellationAction, continuation: continuation)
        }

        guard let result else { return }
        result.action?()
        result.continuation?.resume()
    }
}

/// Idempotent release token for an in-flight provider request.
@MainActor
final class InFlightProviderRequestLease {
    private var releaseAction: (() -> Void)?

    init(_ releaseAction: @escaping () -> Void) {
        self.releaseAction = releaseAction
    }

    func release() {
        guard let releaseAction else { return }
        self.releaseAction = nil
        releaseAction()
    }
}
