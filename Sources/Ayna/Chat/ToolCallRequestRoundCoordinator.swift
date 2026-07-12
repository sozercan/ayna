//
//  ToolCallRequestRoundCoordinator.swift
//  ayna
//
//  Coordinates provider request rounds that can emit multiple tool calls.
//

import Foundation

/// Joins provider completion with every tool completion for one request round.
///
/// Start a distinct round for every provider request and capture its ID in that
/// request's callbacks. Tool registrations retain callback order, while tool
/// results may arrive in any order. Exactly one event receives
/// ``Resolution/launchContinuation(_:)`` once the provider has completed and all
/// registered tools have completed.
@MainActor
final class ToolCallRequestRoundCoordinator<ResultPayload: Sendable> {
    typealias OperationID = ToolChainCoordinator.OperationID

    /// Identifies one provider request within a longer tool-chain operation.
    struct RequestRoundID: Hashable, Sendable {
        fileprivate let rawValue = UUID()
    }

    /// Opaque handle returned for one tool callback in a request round.
    struct ToolToken: Hashable, Sendable {
        let operationID: OperationID
        let requestRoundID: RequestRoundID
        let registrationIndex: Int

        fileprivate init(
            operationID: OperationID,
            requestRoundID: RequestRoundID,
            registrationIndex: Int
        ) {
            self.operationID = operationID
            self.requestRoundID = requestRoundID
            self.registrationIndex = registrationIndex
        }
    }

    /// One completed tool paired with its registration token.
    struct CompletedTool: Sendable {
        let token: ToolToken
        let result: ResultPayload
    }

    /// Ordered tool results needed to launch the next provider request.
    struct Continuation: Sendable {
        let operationID: OperationID
        let completedRequestRoundID: RequestRoundID
        let toolResults: [CompletedTool]
    }

    /// Observable result of closing a provider round or completing a tool.
    enum Resolution: Sendable {
        /// More events are required before the round can resolve.
        case pending

        /// The provider completed without requesting tools.
        case responseCompleted

        /// The caller receiving this value is the sole continuation launcher.
        case launchContinuation(Continuation)

        /// The event was duplicate, stale, cancelled, or for another round.
        case ignored
    }

    private enum ToolCompletion {
        case pending
        case completed(ResultPayload)
    }

    private struct RegisteredTool {
        let token: ToolToken
        var completion: ToolCompletion
    }

    private struct RequestRound {
        let id: RequestRoundID
        let operationID: OperationID
        var providerCompleted = false
        var tools: [RegisteredTool] = []
    }

    private final class OwnershipProbe {
        var isOwned = true
    }

    private var activeOperationID: OperationID?
    private var activeRound: RequestRound?
    private var canBeginRound = false

    /// Starts the next provider request round for an operation.
    ///
    /// Passing a different operation ID replaces any previous state. The round
    /// also registers with `ToolChainCoordinator`, so cancelling or replacing
    /// that operation immediately fences all later round and tool callbacks.
    /// Returns `nil` for a stale operation or when the current round has not yet
    /// produced a continuation decision.
    @discardableResult
    func beginRequestRound(
        for operationID: OperationID,
        coordinatedBy toolChainCoordinator: ToolChainCoordinator
    ) -> RequestRoundID? {
        if activeOperationID != operationID {
            // Registration runs its cancellation immediately when the operation is
            // no longer owned, giving us an ownership check before replacing state.
            let ownershipProbe = OwnershipProbe()
            toolChainCoordinator.onCancel(for: operationID) { [weak self] in
                ownershipProbe.isOwned = false
                self?.cancelOperation(operationID)
            }
            guard ownershipProbe.isOwned else { return nil }

            activeOperationID = operationID
            activeRound = nil
            canBeginRound = true
        }

        guard canBeginRound, activeRound == nil else { return nil }

        let requestRoundID = RequestRoundID()
        activeRound = RequestRound(id: requestRoundID, operationID: operationID)
        canBeginRound = false

        guard activeOperationID == operationID,
              activeRound?.id == requestRoundID
        else {
            return nil
        }

        return requestRoundID
    }

    /// Registers a tool callback in provider callback order.
    ///
    /// Registration is rejected after provider completion closes the round.
    func registerTool(
        for operationID: OperationID,
        requestRoundID: RequestRoundID
    ) -> ToolToken? {
        guard activeOperationID == operationID,
              var round = activeRound,
              round.operationID == operationID,
              round.id == requestRoundID,
              !round.providerCompleted
        else {
            return nil
        }

        let token = ToolToken(
            operationID: operationID,
            requestRoundID: requestRoundID,
            registrationIndex: round.tools.count
        )
        round.tools.append(RegisteredTool(token: token, completion: .pending))
        activeRound = round
        return token
    }

    /// Marks the provider callback stream complete and closes tool registration.
    func providerDidComplete(
        operationID: OperationID,
        requestRoundID: RequestRoundID
    ) -> Resolution {
        guard activeOperationID == operationID,
              var round = activeRound,
              round.operationID == operationID,
              round.id == requestRoundID,
              !round.providerCompleted
        else {
            return .ignored
        }

        round.providerCompleted = true
        activeRound = round
        return resolveIfReady()
    }

    /// Records a tool result. Results are returned in registration order.
    func toolDidComplete(_ token: ToolToken, result: ResultPayload) -> Resolution {
        guard activeOperationID == token.operationID,
              var round = activeRound,
              round.operationID == token.operationID,
              round.id == token.requestRoundID,
              round.tools.indices.contains(token.registrationIndex),
              round.tools[token.registrationIndex].token == token
        else {
            return .ignored
        }

        guard case .pending = round.tools[token.registrationIndex].completion else {
            return .ignored
        }

        round.tools[token.registrationIndex].completion = .completed(result)
        activeRound = round
        return resolveIfReady()
    }

    /// Explicitly clears state for an operation. Normally invoked automatically
    /// by the cancellation hook registered with `ToolChainCoordinator`.
    @discardableResult
    func cancelOperation(_ operationID: OperationID) -> Bool {
        guard activeOperationID == operationID else { return false }
        activeOperationID = nil
        activeRound = nil
        canBeginRound = false
        return true
    }

    private func resolveIfReady() -> Resolution {
        guard let round = activeRound, round.providerCompleted else {
            return .pending
        }

        guard !round.tools.isEmpty else {
            activeRound = nil
            canBeginRound = false
            return .responseCompleted
        }

        var completedTools: [CompletedTool] = []
        completedTools.reserveCapacity(round.tools.count)

        for tool in round.tools {
            guard case let .completed(result) = tool.completion else {
                return .pending
            }
            completedTools.append(CompletedTool(token: tool.token, result: result))
        }

        activeRound = nil
        canBeginRound = true
        return .launchContinuation(
            Continuation(
                operationID: round.operationID,
                completedRequestRoundID: round.id,
                toolResults: completedTools
            )
        )
    }
}
