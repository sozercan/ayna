//
//  WatchConnectivityLifecycleSupport.swift
//  Ayna
//
//  FIFO callback and legacy-operation lifecycle helpers.
//

import Foundation

struct WatchSessionActivationToken: Equatable, Sendable {
    fileprivate let generation: UInt64
}

final class WatchSessionActivationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func beginActivation() -> WatchSessionActivationToken {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        if generation == 0 {
            generation = 1
        }
        return WatchSessionActivationToken(generation: generation)
    }

    func isCurrent(_ activation: WatchSessionActivationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == activation.generation
    }
}

#if os(iOS) || os(watchOS)
    import WatchConnectivity
#endif

#if os(iOS)
    final class WatchSessionDelegateProxy: NSObject, WCSessionDelegate, @unchecked Sendable {
        private weak var owner: WatchConnectivityService?
        let activation: WatchSessionActivationToken

        init(
            owner: WatchConnectivityService,
            activation: WatchSessionActivationToken
        ) {
            self.owner = owner
            self.activation = activation
        }

        func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: Error?
        ) {
            owner?.handleSessionActivation(
                session,
                activation: activation,
                state: activationState,
                error: error
            )
        }

        func sessionDidBecomeInactive(_ session: WCSession) {
            owner?.handleSessionDidBecomeInactive(session, activation: activation)
        }

        func sessionDidDeactivate(_ session: WCSession) {
            owner?.handleSessionDidDeactivate(session, activation: activation)
        }

        func sessionWatchStateDidChange(_ session: WCSession) {
            owner?.handleSessionWatchStateDidChange(session, activation: activation)
        }

        func sessionReachabilityDidChange(_ session: WCSession) {
            owner?.handleSessionReachabilityDidChange(session, activation: activation)
        }

        func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
            owner?.handleSession(
                session,
                activation: activation,
                didReceiveMessage: message
            )
        }

        func session(
            _ session: WCSession,
            didReceiveMessage message: [String: Any],
            replyHandler: @escaping ([String: Any]) -> Void
        ) {
            owner?.handleSession(
                session,
                activation: activation,
                didReceiveMessage: message,
                replyHandler: replyHandler
            )
        }

        func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
            owner?.handleSession(
                session,
                activation: activation,
                didReceiveUserInfo: userInfo
            )
        }

        func session(_ session: WCSession, didReceive file: WCSessionFile) {
            owner?.handleSession(session, activation: activation, didReceive: file)
        }
    }
#elseif os(watchOS)
    final class WatchSessionDelegateProxy: NSObject, WCSessionDelegate, @unchecked Sendable {
        private weak var owner: WatchConnectivityService?
        let activation: WatchSessionActivationToken

        init(
            owner: WatchConnectivityService,
            activation: WatchSessionActivationToken
        ) {
            self.owner = owner
            self.activation = activation
        }

        func session(
            _ session: WCSession,
            activationDidCompleteWith activationState: WCSessionActivationState,
            error: Error?
        ) {
            owner?.handleSessionActivation(
                session,
                activation: activation,
                state: activationState,
                error: error
            )
        }

        func sessionReachabilityDidChange(_ session: WCSession) {
            owner?.handleSessionReachabilityDidChange(session, activation: activation)
        }

        func session(
            _ session: WCSession,
            didReceiveApplicationContext applicationContext: [String: Any]
        ) {
            owner?.handleSession(
                session,
                activation: activation,
                didReceiveApplicationContext: applicationContext
            )
        }

        func session(
            _ session: WCSession,
            didFinish userInfoTransfer: WCSessionUserInfoTransfer,
            error: Error?
        ) {
            owner?.handleSession(
                session,
                activation: activation,
                didFinish: userInfoTransfer,
                error: error
            )
        }

        func session(
            _ session: WCSession,
            didFinish fileTransfer: WCSessionFileTransfer,
            error: Error?
        ) {
            owner?.handleSession(
                session,
                activation: activation,
                didFinish: fileTransfer,
                error: error
            )
        }
    }
#endif

final class WatchSessionEventQueue: @unchecked Sendable {
    private struct Event: Sendable {
        let operation: @MainActor @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var events: [Event] = []
    private var nextIndex = 0
    private var drainScheduled = false

    func enqueue(_ operation: @escaping @MainActor @Sendable () async -> Void) {
        lock.lock()
        events.append(Event(operation: operation))
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    @MainActor
    private func drain() async {
        while let event = dequeue() {
            await event.operation()
        }
    }

    private func dequeue() -> Event? {
        lock.lock()
        defer { lock.unlock() }
        guard events.indices.contains(nextIndex) else {
            events.removeAll(keepingCapacity: true)
            nextIndex = 0
            drainScheduled = false
            return nil
        }
        let event = events[nextIndex]
        nextIndex += 1
        return event
    }
}

enum WatchLegacyIngressRouting {
    static func shouldDefer(
        isAuthoritative: Bool,
        pendingDestructiveOperationCount: Int
    ) -> Bool {
        !isAuthoritative || pendingDestructiveOperationCount > 0
    }
}

@MainActor
final class WatchLegacyIngressDeferralQueue {
    private struct DeferredOperation {
        let waitUntilReady: @MainActor @Sendable () async -> Bool
        let operation: @MainActor @Sendable () async -> Void
    }

    private var operations: [DeferredOperation] = []
    private var drainTask: Task<Void, Never>?

    func retain(
        untilReady waitUntilReady: @escaping @MainActor @Sendable () async -> Bool,
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        operations.append(DeferredOperation(
            waitUntilReady: waitUntilReady,
            operation: operation
        ))
        scheduleDrain()
    }

    private func scheduleDrain() {
        guard drainTask == nil, !operations.isEmpty else { return }
        drainTask = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let deferred = operations.first {
            guard await deferred.waitUntilReady(), !Task.isCancelled else {
                drainTask = nil
                return
            }
            operations.removeFirst()
            await deferred.operation()
        }
        drainTask = nil
    }
}

enum WatchStandaloneHandshakeDisposition: Equatable, Sendable {
    case requestFreshCycle
    case preservePendingFreshCycle
    case retireWithoutRequest
}

struct WatchPageCycleHandshakeTracker: Sendable {
    private struct StandaloneIdentity: Equatable, Sendable {
        let sourceID: UUID
        let revision: WatchSyncRevision
    }

    private var lastStandaloneIdentity: StandaloneIdentity?

    mutating func disposition(
        sourceID: UUID,
        snapshotRevision: WatchSyncRevision,
        pendingRequest: WatchSyncRequestIdentity?
    ) -> WatchStandaloneHandshakeDisposition {
        let identity = StandaloneIdentity(
            sourceID: sourceID,
            revision: snapshotRevision
        )
        guard lastStandaloneIdentity == identity else {
            lastStandaloneIdentity = identity
            return .requestFreshCycle
        }
        return pendingRequest == .freshCycle
            ? .preservePendingFreshCycle
            : .retireWithoutRequest
    }

    mutating func pageCycleReceived() {
        lastStandaloneIdentity = nil
    }

    mutating func reset() {
        lastStandaloneIdentity = nil
    }
}

enum WatchPageCycleRetryBackoff {
    static func seconds(forAttempt attempt: Int) -> TimeInterval {
        let boundedAttempt = min(max(0, attempt), 4)
        return min(60, 5 * pow(2, Double(boundedAttempt)))
    }
}

@MainActor
final class WatchPageCycleRequestRetryController {
    typealias Sleep = @MainActor @Sendable (TimeInterval) async throws -> Void

    private let sleep: Sleep
    private var retryTask: Task<Void, Never>?
    private(set) var pendingRequest: WatchSyncRequestIdentity?

    init(
        sleep: @escaping Sleep = { delay in
            try await Task.sleep(for: .seconds(delay))
        }
    ) {
        self.sleep = sleep
    }

    func retain(
        _ request: WatchSyncRequestIdentity?,
        resend: @escaping @MainActor @Sendable (WatchSyncRequestIdentity) -> Void
    ) {
        guard request != pendingRequest else { return }
        retryTask?.cancel()
        retryTask = nil
        pendingRequest = request
        guard let request else { return }

        retryTask = Task { @MainActor [weak self] in
            var attempt = 0
            while let self,
                  self.pendingRequest == request,
                  !Task.isCancelled
            {
                let delay = WatchPageCycleRetryBackoff.seconds(forAttempt: attempt)
                do {
                    try await self.sleep(delay)
                } catch {
                    return
                }
                guard self.pendingRequest == request, !Task.isCancelled else { return }
                resend(request)
                attempt += 1
            }
        }
    }

    func cancel() {
        retryTask?.cancel()
        retryTask = nil
        pendingRequest = nil
    }
}

struct WatchLegacyMutationMetadata {
    let peerID: UUID?
    let revision: WatchSyncRevision?

    init(message: [String: Any]) {
        peerID = (message[WatchMessageKeys.peerId] as? String).flatMap(UUID.init(uuidString:))
        revision = WatchSyncValueDecoder.revision(message[WatchMessageKeys.mutationRevision])
    }

    func isFromActivePeer(_ activePeerID: UUID?) -> Bool {
        guard let peerID else { return true }
        return peerID == activePeerID
    }

    func isCovered(
        conversationID: UUID,
        activePeerID: UUID?,
        acknowledgements: [UUID: WatchSyncRevision]
    ) -> Bool {
        guard let peerID, peerID == activePeerID, let revision else { return false }
        return acknowledgements[conversationID, default: 0] >= revision
    }
}

enum WatchLegacyCreateIngressAction: Equatable, Sendable {
    case ignore
    case create
    case repairPlaceholder
}

enum WatchLegacyCreateIngressResolver {
    static func action(
        metadata: WatchLegacyMutationMetadata,
        conversationID: UUID,
        activePeerID: UUID?,
        acknowledgements: [UUID: WatchSyncRevision],
        conversationExists: Bool,
        isTrackedPlaceholder: Bool
    ) -> WatchLegacyCreateIngressAction {
        if metadata.isCovered(
            conversationID: conversationID,
            activePeerID: activePeerID,
            acknowledgements: acknowledgements
        ) {
            return .ignore
        }
        guard metadata.isFromActivePeer(activePeerID) else {
            return .ignore
        }
        guard conversationExists else { return .create }
        return isTrackedPlaceholder ? .repairPlaceholder : .ignore
    }
}

struct WatchLegacySendResult {
    let userInfos: [[String: Any]]
    let componentIDs: Set<String>
    let awaitingEchoComponentIDs: Set<String>
    let fullyRepresented: Bool

    var requiresEchoRetry: Bool {
        !awaitingEchoComponentIDs.isEmpty
    }

    init(
        userInfos: [[String: Any]],
        awaitingEchoComponentIDs: Set<String> = [],
        fullyRepresented: Bool
    ) {
        self.userInfos = userInfos
        componentIDs = Set(userInfos.compactMap {
            $0[WatchMessageKeys.legacyComponentId] as? String
        })
        self.awaitingEchoComponentIDs = awaitingEchoComponentIDs
        self.fullyRepresented = fullyRepresented
    }
}

@MainActor
final class WatchLegacyAcknowledgementRetryTracker {
    struct PendingAcknowledgement: Equatable, Sendable {
        let operationID: UUID
        let conversationID: UUID
        let revision: WatchSyncRevision
    }

    private var pendingByOperationID: [UUID: PendingAcknowledgement] = [:]

    func retain(_ mutation: WatchConversationMutation) {
        pendingByOperationID[mutation.operationID] = PendingAcknowledgement(
            operationID: mutation.operationID,
            conversationID: mutation.conversationID,
            revision: mutation.revision
        )
    }

    func contains(operationID: UUID) -> Bool {
        pendingByOperationID[operationID] != nil
    }

    func retry(
        _ acknowledge: @MainActor (UUID, WatchSyncRevision) -> Bool
    ) -> [PendingAcknowledgement] {
        let pending = pendingByOperationID.values.sorted {
            if $0.revision != $1.revision {
                return $0.revision < $1.revision
            }
            return $0.operationID.uuidString < $1.operationID.uuidString
        }
        var acknowledged: [PendingAcknowledgement] = []
        for acknowledgement in pending where acknowledge(
            acknowledgement.conversationID,
            acknowledgement.revision
        ) {
            pendingByOperationID.removeValue(forKey: acknowledgement.operationID)
            acknowledged.append(acknowledgement)
        }
        return acknowledged
    }

    func cancel(operationID: UUID) {
        pendingByOperationID.removeValue(forKey: operationID)
    }

    func reset() {
        pendingByOperationID.removeAll()
    }
}

@MainActor
final class WatchLegacyOperationTracker {
    private struct PendingOperation {
        let conversationID: UUID
        let revision: WatchSyncRevision
        var remainingComponentIDs: Set<String>
        let fullyRepresented: Bool
    }

    private var operations: [UUID: PendingOperation] = [:]

    func begin(_ mutation: WatchConversationMutation, result: WatchLegacySendResult) {
        operations[mutation.operationID] = PendingOperation(
            conversationID: mutation.conversationID,
            revision: mutation.revision,
            remainingComponentIDs: result.componentIDs,
            fullyRepresented: result.fullyRepresented
        )
    }

    func completion(
        operationID: UUID,
        componentID: String
    ) -> (conversationID: UUID, revision: WatchSyncRevision)? {
        guard var operation = operations[operationID] else { return nil }
        operation.remainingComponentIDs.remove(componentID)
        guard operation.remainingComponentIDs.isEmpty else {
            operations[operationID] = operation
            return nil
        }
        operations.removeValue(forKey: operationID)
        guard operation.fullyRepresented else { return nil }
        return (operation.conversationID, operation.revision)
    }

    func cancel(operationID: UUID) {
        operations.removeValue(forKey: operationID)
    }

    func reset() {
        operations.removeAll()
    }
}
