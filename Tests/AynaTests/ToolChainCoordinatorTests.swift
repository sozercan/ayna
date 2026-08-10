@testable import Ayna
import Foundation
import Testing

@Suite("Tool Chain Coordinator Tests", .tags(.async))
@MainActor
struct ToolChainCoordinatorTests {
    @Test
    func `provider callback bookkeeping preserves enqueue order`() async throws {
        let coordinator = ToolChainCoordinator()
        let requestRounds = ToolCallRequestRoundCoordinator<String>()
        let conversationID = UUID()
        let operationID = coordinator.beginOperation(conversationID: conversationID)
        let requestRoundID = try #require(
            requestRounds.beginRequestRound(for: operationID, coordinatedBy: coordinator)
        )
        let drained = FlightTestSignal()
        var callbackOrder: [String] = []
        var registrationIndexes: [Int] = []
        var completionWaitedForTools = false

        coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
            callbackOrder.append("chunk")
        }
        coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
            if let token = requestRounds.registerTool(
                for: operationID,
                requestRoundID: requestRoundID
            ) {
                registrationIndexes.append(token.registrationIndex)
            }
            callbackOrder.append("tool-1")
        }
        coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
            if let token = requestRounds.registerTool(
                for: operationID,
                requestRoundID: requestRoundID
            ) {
                registrationIndexes.append(token.registrationIndex)
            }
            callbackOrder.append("tool-2")
        }
        coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
            let resolution = requestRounds.providerDidComplete(
                operationID: operationID,
                requestRoundID: requestRoundID
            )
            if case .pending = resolution {
                completionWaitedForTools = true
            }
            callbackOrder.append("complete")
            drained.signal()
        }

        #expect(await drained.wait(timeout: .seconds(1)))
        #expect(callbackOrder == ["chunk", "tool-1", "tool-2", "complete"])
        #expect(registrationIndexes == [0, 1])
        #expect(completionWaitedForTools)
        coordinator.cancelCurrentOperation()
    }

    @Test
    func `callback handoff is safe to enqueue off the main actor`() async {
        let coordinator = ToolChainCoordinator()
        let conversationID = UUID()
        let operationID = coordinator.beginOperation(conversationID: conversationID)
        let observed = FlightTestBox<[Int]>([])
        let drained = FlightTestSignal()

        await Task.detached {
            for value in 0 ..< 20 {
                coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
                    observed.update { $0.append(value) }
                    if value == 19 {
                        drained.signal()
                    }
                }
            }
        }.value

        #expect(await drained.wait(timeout: .seconds(1)))
        #expect(observed.value == Array(0 ..< 20))
        coordinator.cancelCurrentOperation()
    }

    @Test
    func `cancellation suppresses callbacks already waiting for the main actor`() async {
        let coordinator = ToolChainCoordinator()
        let conversationID = UUID()
        let operationID = coordinator.beginOperation(conversationID: conversationID)
        let staleMutation = FlightTestSignal()

        coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
            staleMutation.signal()
        }
        #expect(coordinator.cancelCurrentOperation())

        #expect(await !(staleMutation.wait(timeout: .milliseconds(100))))
    }

    @Test
    func `lifecycle cancellation drains bookkeeping before finalization and invalidation`() {
        let coordinator = ToolChainCoordinator()
        let conversationID = UUID()
        let operationID = coordinator.beginOperation(conversationID: conversationID)
        var callbackOrder: [String] = []
        var ownedDuringFinalization = false

        coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
            callbackOrder.append("chunk")
        }
        coordinator.enqueueCallback(for: operationID, conversationID: conversationID) {
            callbackOrder.append("status")
        }

        #expect(coordinator.cancelCurrentOperation {
            ownedDuringFinalization = coordinator.owns(operationID, conversationID: conversationID)
            callbackOrder.append("finalize")
        })

        #expect(callbackOrder == ["chunk", "status", "finalize"])
        #expect(ownedDuringFinalization)
        #expect(!coordinator.owns(operationID, conversationID: conversationID))
    }

    @Test
    func `replacement suppresses queued callbacks from the previous operation`() async {
        let coordinator = ToolChainCoordinator()
        let firstConversationID = UUID()
        let firstOperationID = coordinator.beginOperation(conversationID: firstConversationID)
        let observed = FlightTestBox<[String]>([])
        let replacementRan = FlightTestSignal()

        coordinator.enqueueCallback(for: firstOperationID, conversationID: firstConversationID) {
            observed.update { $0.append("stale") }
        }

        let secondConversationID = UUID()
        let secondOperationID = coordinator.beginOperation(conversationID: secondConversationID)
        coordinator.enqueueCallback(for: secondOperationID, conversationID: secondConversationID) {
            observed.update { $0.append("replacement") }
            replacementRan.signal()
        }

        #expect(await replacementRan.wait(timeout: .seconds(1)))
        #expect(observed.value == ["replacement"])
        coordinator.cancelCurrentOperation()
    }

    @Test
    func `scheduled async work is not serialized by callback ordering`() async {
        let coordinator = ToolChainCoordinator()
        let conversationID = UUID()
        let operationID = coordinator.beginOperation(conversationID: conversationID)
        let firstStarted = FlightTestSignal()
        let releaseFirst = FlightTestSignal()
        let firstFinished = FlightTestSignal()
        let secondStarted = FlightTestSignal()

        coordinator.schedule(for: operationID, conversationID: conversationID) {
            firstStarted.signal()
            await releaseFirst.wait()
            firstFinished.signal()
        }
        coordinator.schedule(for: operationID, conversationID: conversationID) {
            secondStarted.signal()
        }

        #expect(await firstStarted.wait(timeout: .seconds(1)))
        #expect(await secondStarted.wait(timeout: .seconds(1)))
        #expect(!firstFinished.isSignaled)

        releaseFirst.signal()
        #expect(await firstFinished.wait(timeout: .seconds(1)))
        coordinator.cancelCurrentOperation()
    }

    @Test
    func `cancelling a chain stops its tool task and suppresses late completion`() async {
        let coordinator = ToolChainCoordinator()
        let conversationID = UUID()
        let operationID = coordinator.beginOperation(conversationID: conversationID)
        let cancellationObserved = FlightTestSignal()
        let allowLateCompletion = FlightTestSignal()
        let staleMutation = FlightTestSignal()

        let task = Task {
            await withTaskCancellationHandler {
                await allowLateCompletion.wait()
                coordinator.schedule(for: operationID, conversationID: conversationID) {
                    staleMutation.signal()
                }
            } onCancel: {
                cancellationObserved.signal()
            }
        }
        coordinator.track(task, for: operationID)

        #expect(coordinator.cancelCurrentOperation())
        #expect(await cancellationObserved.wait(timeout: .seconds(1)))
        allowLateCompletion.signal()
        #expect(await !(staleMutation.wait(timeout: .milliseconds(100))))
        #expect(!coordinator.owns(operationID, conversationID: conversationID))
    }

    @Test
    func `replacement cancels the old tool chain without surrendering ownership`() async {
        let coordinator = ToolChainCoordinator()
        let firstConversationID = UUID()
        let secondConversationID = UUID()
        let firstID = coordinator.beginOperation(conversationID: firstConversationID)
        let cancellationObserved = FlightTestSignal()
        let blocker = FlightTestSignal()
        let firstTask = Task {
            await withTaskCancellationHandler {
                await blocker.wait()
            } onCancel: {
                cancellationObserved.signal()
            }
        }
        coordinator.track(firstTask, for: firstID)

        let secondID = coordinator.beginOperation(conversationID: secondConversationID)

        #expect(await cancellationObserved.wait(timeout: .seconds(1)))
        #expect(!coordinator.owns(firstID, conversationID: firstConversationID))
        #expect(coordinator.owns(secondID, conversationID: secondConversationID))
        #expect(!coordinator.finishOperation(firstID))
        #expect(coordinator.owns(secondID, conversationID: secondConversationID))

        blocker.signal()
        coordinator.cancelCurrentOperation()
    }

    @Test
    func `tracking work after cancellation cancels it immediately`() async {
        let coordinator = ToolChainCoordinator()
        let operationID = coordinator.beginOperation(conversationID: UUID())
        coordinator.cancelCurrentOperation()
        let cancellationObserved = FlightTestSignal()
        let blocker = FlightTestSignal()
        let task = Task {
            await withTaskCancellationHandler {
                await blocker.wait()
            } onCancel: {
                cancellationObserved.signal()
            }
        }

        coordinator.track(task, for: operationID)

        #expect(await cancellationObserved.wait(timeout: .seconds(1)))
        blocker.signal()
    }

    @Test
    func `finishing a chain does not run cancellation cleanup`() {
        let coordinator = ToolChainCoordinator()
        let operationID = coordinator.beginOperation(conversationID: UUID())
        var cleanupCount = 0
        coordinator.onCancel(for: operationID) {
            cleanupCount += 1
        }

        #expect(coordinator.finishOperation(operationID))
        #expect(!coordinator.cancelCurrentOperation())
        #expect(cleanupCount == 0)
    }
}
