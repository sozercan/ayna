import Foundation

enum ToolCallRequestRoundPolicy {
    static let maximumToolCallsPerRound = 8

    static func canonicalArguments(_ arguments: [String: AnyCodable]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(arguments)) ?? Data()
    }
}

final class ToolCallRequestAdmissionGate: @unchecked Sendable {
    private enum CallbackIdentity: Hashable {
        case providerID(String)
        case idLess(toolName: String, encodedArguments: Data)
    }

    private let lock = NSLock()
    private var admittedCallbacks: Set<CallbackIdentity> = []
    private var admittedCount = 0

    func admit(providerID: String) -> Bool {
        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return admit(identity: .providerID(normalizedProviderID))
    }

    private func admit(
        providerID: String,
        toolName: String,
        arguments: [String: Any]
    ) -> Bool {
        let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToolName.isEmpty else { return false }

        let normalizedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedProviderID.isEmpty {
            return admit(identity: .providerID(normalizedProviderID))
        }

        let codableArguments = arguments.mapValues(AnyCodable.init)
        return admit(
            identity: .idLess(
                toolName: normalizedToolName,
                encodedArguments: ToolCallRequestRoundPolicy.canonicalArguments(codableArguments)
            )
        )
    }

    private func admit(identity: CallbackIdentity) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !admittedCallbacks.contains(identity) else { return false }
        guard admittedCount < ToolCallRequestRoundPolicy.maximumToolCallsPerRound else {
            return false
        }

        admittedCount += 1
        admittedCallbacks.insert(identity)
        return true
    }

    func admittedCallback(
        _ callback: @escaping @Sendable (String, String, [String: Any]) -> Void
    ) -> @Sendable (String, String, [String: Any]) -> Void {
        { providerID, toolName, arguments in
            guard self.admit(
                providerID: providerID,
                toolName: toolName,
                arguments: arguments
            ) else {
                return
            }
            callback(providerID, toolName, arguments)
        }
    }
}

@MainActor
final class ToolCallRequestRoundCoordinator<ResultPayload: Sendable> {
    typealias OperationID = ToolChainCoordinator.OperationID

    struct RequestRoundID: Hashable, Sendable {
        fileprivate let rawValue = UUID()
    }

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

    struct CompletedTool: Sendable {
        let token: ToolToken
        let result: ResultPayload
    }

    struct Continuation: Sendable {
        let operationID: OperationID
        let completedRequestRoundID: RequestRoundID
        let toolResults: [CompletedTool]
    }

    enum Resolution: Sendable {
        case pending

        case responseCompleted

        case launchContinuation(Continuation)

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

    @discardableResult
    func beginRequestRound(
        for operationID: OperationID,
        coordinatedBy toolChainCoordinator: ToolChainCoordinator
    ) -> RequestRoundID? {
        if activeOperationID != operationID {
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

    func registerTool(
        for operationID: OperationID,
        requestRoundID: RequestRoundID
    ) -> ToolToken? {
        guard activeOperationID == operationID,
              var round = activeRound,
              round.operationID == operationID,
              round.id == requestRoundID,
              !round.providerCompleted,
              round.tools.count < ToolCallRequestRoundPolicy.maximumToolCallsPerRound
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
