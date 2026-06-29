//
//  InFlightProviderRequests.swift
//  ayna
//
//  Owns provider adapters for the lifetime of in-flight provider requests.
//

import Foundation

/// Retains per-request provider adapters and releases/cancels them by request id.
///
/// Provider adapters are not safe to reuse as singletons while multi-model calls
/// can run multiple same-provider streams concurrently, because adapters own their
/// current stream task. This Module keeps request lifetime ownership local and
/// makes future provider registry work safer.
@MainActor
final class InFlightProviderRequests {
    private var providersByRequestId: [UUID: any AIProviderProtocol] = [:]

    var count: Int {
        providersByRequestId.count
    }

    func retain(_ provider: any AIProviderProtocol, requestId: UUID = UUID()) -> InFlightProviderRequestLease {
        providersByRequestId[requestId] = provider
        return InFlightProviderRequestLease { [weak self] in
            self?.providersByRequestId.removeValue(forKey: requestId)
        }
    }

    func cancelAll() {
        let providers = Array(providersByRequestId.values)
        providersByRequestId.removeAll()
        for provider in providers {
            provider.cancelRequest()
        }
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
