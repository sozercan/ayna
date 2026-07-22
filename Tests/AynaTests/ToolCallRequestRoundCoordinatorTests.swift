@testable import Ayna
import Foundation
import Testing

@Suite("Tool Call Request Round Coordinator Tests", .tags(.fast))
@MainActor
struct ToolCallRequestRoundCoordinatorTests {
    private struct ToolResult: Equatable, Sendable {
        let callID: String
        let output: String
    }

    private typealias Coordinator = ToolCallRequestRoundCoordinator<ToolResult>

    @Test
    func `two parallel tools launch exactly one continuation after every completion`() throws {
        let toolChainCoordinator = ToolChainCoordinator()
        let coordinator = Coordinator()
        let operationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let roundID = try #require(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            )
        )
        let firstToken = try #require(
            coordinator.registerTool(for: operationID, requestRoundID: roundID)
        )
        let secondToken = try #require(
            coordinator.registerTool(for: operationID, requestRoundID: roundID)
        )

        let providerResolution = coordinator.providerDidComplete(
            operationID: operationID,
            requestRoundID: roundID
        )
        guard case .pending = providerResolution else {
            Issue.record("Provider completion must wait for both tools")
            return
        }
        #expect(coordinator.registerTool(for: operationID, requestRoundID: roundID) == nil)

        let firstResolution = coordinator.toolDidComplete(
            firstToken,
            result: ToolResult(callID: "first", output: "one")
        )
        guard case .pending = firstResolution else {
            Issue.record("The first tool must not launch the continuation alone")
            return
        }

        let secondResolution = coordinator.toolDidComplete(
            secondToken,
            result: ToolResult(callID: "second", output: "two")
        )
        guard case let .launchContinuation(continuation) = secondResolution else {
            Issue.record("The final tool should launch the continuation")
            return
        }

        #expect(continuation.operationID == operationID)
        #expect(continuation.completedRequestRoundID == roundID)
        #expect(continuation.toolResults.map(\.token) == [firstToken, secondToken])
        #expect(continuation.toolResults.map(\.result) == [
            ToolResult(callID: "first", output: "one"),
            ToolResult(callID: "second", output: "two"),
        ])

        let duplicateResolution = coordinator.toolDidComplete(
            secondToken,
            result: ToolResult(callID: "second", output: "duplicate")
        )
        guard case .ignored = duplicateResolution else {
            Issue.record("A resolved round must not launch a second continuation")
            return
        }
    }

    @Test
    func `reverse tool completion preserves original callback order`() throws {
        let toolChainCoordinator = ToolChainCoordinator()
        let coordinator = Coordinator()
        let operationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let roundID = try #require(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            )
        )
        let firstToken = try #require(
            coordinator.registerTool(for: operationID, requestRoundID: roundID)
        )
        let secondToken = try #require(
            coordinator.registerTool(for: operationID, requestRoundID: roundID)
        )

        let secondResolution = coordinator.toolDidComplete(
            secondToken,
            result: ToolResult(callID: "second", output: "finished first")
        )
        guard case .pending = secondResolution else {
            Issue.record("An out-of-order tool completion must wait")
            return
        }

        let providerResolution = coordinator.providerDidComplete(
            operationID: operationID,
            requestRoundID: roundID
        )
        guard case .pending = providerResolution else {
            Issue.record("Provider completion must still wait for the first tool")
            return
        }

        let firstResolution = coordinator.toolDidComplete(
            firstToken,
            result: ToolResult(callID: "first", output: "finished second")
        )
        guard case let .launchContinuation(continuation) = firstResolution else {
            Issue.record("The last outstanding tool should launch the continuation")
            return
        }

        #expect(continuation.toolResults.map(\.token) == [firstToken, secondToken])
        #expect(continuation.toolResults.map(\.result.callID) == ["first", "second"])
    }

    @Test
    func `synchronous tool completion waits for onComplete and fences the next round`() throws {
        let toolChainCoordinator = ToolChainCoordinator()
        let coordinator = Coordinator()
        let operationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let originalRoundID = try #require(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            )
        )
        let toolToken = try #require(
            coordinator.registerTool(for: operationID, requestRoundID: originalRoundID)
        )

        let synchronousToolResolution = coordinator.toolDidComplete(
            toolToken,
            result: ToolResult(callID: "sync", output: "ready")
        )
        guard case .pending = synchronousToolResolution else {
            Issue.record("A synchronous tool must wait for provider onComplete")
            return
        }
        #expect(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            ) == nil
        )

        let providerResolution = coordinator.providerDidComplete(
            operationID: operationID,
            requestRoundID: originalRoundID
        )
        guard case .launchContinuation = providerResolution else {
            Issue.record("Provider onComplete should release the synchronous tool result")
            return
        }

        let continuationRoundID = try #require(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            )
        )

        let lateOriginalCompletion = coordinator.providerDidComplete(
            operationID: operationID,
            requestRoundID: originalRoundID
        )
        guard case .ignored = lateOriginalCompletion else {
            Issue.record("The original round must not close its continuation round")
            return
        }

        #expect(
            coordinator.registerTool(
                for: operationID,
                requestRoundID: continuationRoundID
            ) != nil
        )
    }

    @Test
    func `replacing the operation suppresses stale round and tool completions`() throws {
        let toolChainCoordinator = ToolChainCoordinator()
        let coordinator = Coordinator()
        let firstOperationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let firstRoundID = try #require(
            coordinator.beginRequestRound(
                for: firstOperationID,
                coordinatedBy: toolChainCoordinator
            )
        )
        let firstToken = try #require(
            coordinator.registerTool(for: firstOperationID, requestRoundID: firstRoundID)
        )

        let secondOperationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let secondRoundID = try #require(
            coordinator.beginRequestRound(
                for: secondOperationID,
                coordinatedBy: toolChainCoordinator
            )
        )

        let staleProviderResolution = coordinator.providerDidComplete(
            operationID: firstOperationID,
            requestRoundID: firstRoundID
        )
        guard case .ignored = staleProviderResolution else {
            Issue.record("A replaced provider round must be ignored")
            return
        }

        let staleToolResolution = coordinator.toolDidComplete(
            firstToken,
            result: ToolResult(callID: "stale", output: "ignored")
        )
        guard case .ignored = staleToolResolution else {
            Issue.record("A replaced tool completion must be ignored")
            return
        }

        let secondToken = try #require(
            coordinator.registerTool(for: secondOperationID, requestRoundID: secondRoundID)
        )
        let secondToolResolution = coordinator.toolDidComplete(
            secondToken,
            result: ToolResult(callID: "current", output: "kept")
        )
        guard case .pending = secondToolResolution else {
            Issue.record("The replacement round should remain active")
            return
        }

        let secondProviderResolution = coordinator.providerDidComplete(
            operationID: secondOperationID,
            requestRoundID: secondRoundID
        )
        guard case let .launchContinuation(continuation) = secondProviderResolution else {
            Issue.record("The replacement operation should launch normally")
            return
        }
        #expect(continuation.operationID == secondOperationID)
        #expect(continuation.toolResults.map(\.result.callID) == ["current"])
    }

    @Test
    func `stale round begin cannot erase the active replacement round`() throws {
        let toolChainCoordinator = ToolChainCoordinator()
        let coordinator = Coordinator()
        let staleOperationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        _ = try #require(
            coordinator.beginRequestRound(
                for: staleOperationID,
                coordinatedBy: toolChainCoordinator
            )
        )

        let replacementOperationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let replacementRoundID = try #require(
            coordinator.beginRequestRound(
                for: replacementOperationID,
                coordinatedBy: toolChainCoordinator
            )
        )

        #expect(
            coordinator.beginRequestRound(
                for: staleOperationID,
                coordinatedBy: toolChainCoordinator
            ) == nil
        )

        let replacementToken = try #require(
            coordinator.registerTool(
                for: replacementOperationID,
                requestRoundID: replacementRoundID
            )
        )
        guard case .pending = coordinator.toolDidComplete(
            replacementToken,
            result: ToolResult(callID: "replacement", output: "kept")
        ) else {
            Issue.record("The stale begin must not clear replacement tool registration")
            return
        }

        let resolution = coordinator.providerDidComplete(
            operationID: replacementOperationID,
            requestRoundID: replacementRoundID
        )
        guard case let .launchContinuation(continuation) = resolution else {
            Issue.record("The active replacement round should still resolve")
            return
        }
        #expect(continuation.operationID == replacementOperationID)
        #expect(continuation.toolResults.map(\.result.callID) == ["replacement"])
    }

    @Test
    func `cancellation suppresses all later completions`() throws {
        let toolChainCoordinator = ToolChainCoordinator()
        let coordinator = Coordinator()
        let operationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let roundID = try #require(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            )
        )
        let token = try #require(
            coordinator.registerTool(for: operationID, requestRoundID: roundID)
        )

        #expect(toolChainCoordinator.cancelCurrentOperation())

        let providerResolution = coordinator.providerDidComplete(
            operationID: operationID,
            requestRoundID: roundID
        )
        guard case .ignored = providerResolution else {
            Issue.record("Provider completion after cancellation must be ignored")
            return
        }

        let toolResolution = coordinator.toolDidComplete(
            token,
            result: ToolResult(callID: "cancelled", output: "ignored")
        )
        guard case .ignored = toolResolution else {
            Issue.record("Tool completion after cancellation must be ignored")
            return
        }

        #expect(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            ) == nil
        )
    }

    @Test
    func `provider completion closes a round with no tools`() throws {
        let toolChainCoordinator = ToolChainCoordinator()
        let coordinator = Coordinator()
        let operationID = toolChainCoordinator.beginOperation(conversationID: UUID())
        let roundID = try #require(
            coordinator.beginRequestRound(
                for: operationID,
                coordinatedBy: toolChainCoordinator
            )
        )

        let resolution = coordinator.providerDidComplete(
            operationID: operationID,
            requestRoundID: roundID
        )
        guard case .responseCompleted = resolution else {
            Issue.record("A no-tool response should complete without a continuation")
            return
        }

        #expect(coordinator.registerTool(for: operationID, requestRoundID: roundID) == nil)

        let duplicateResolution = coordinator.providerDidComplete(
            operationID: operationID,
            requestRoundID: roundID
        )
        guard case .ignored = duplicateResolution else {
            Issue.record("A closed round must ignore duplicate provider completion")
            return
        }
    }
}
