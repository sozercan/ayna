@testable import Ayna
import Foundation
import Testing

#if !os(watchOS)
    @Suite("Image Generation Coordinator Tests", .tags(.async))
    @MainActor
    struct ImageGenerationCoordinatorTests {
        @Test("Replacement cancels the previous operation without surrendering ownership")
        func replacementCancelsPreviousOperationWithoutSurrenderingOwnership() async {
            let coordinator = ImageGenerationCoordinator()
            let firstID = coordinator.beginOperation()
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

            let secondID = coordinator.beginOperation()
            let cancelled = await cancellationObserved.wait(timeout: .seconds(1))

            #expect(cancelled)
            #expect(!coordinator.owns(firstID))
            #expect(coordinator.owns(secondID))
            #expect(!coordinator.finishOperation(firstID))
            #expect(coordinator.owns(secondID))

            blocker.signal()
            coordinator.cancelCurrentOperation()
        }

        @Test("Scheduled stale work is suppressed while current work runs")
        func scheduledStaleWorkIsSuppressedWhileCurrentWorkRuns() async {
            let coordinator = ImageGenerationCoordinator()
            let staleID = coordinator.beginOperation()
            let currentID = coordinator.beginOperation()
            let staleRan = FlightTestSignal()
            let currentRan = FlightTestSignal()

            coordinator.schedule(for: staleID) {
                staleRan.signal()
            }
            coordinator.schedule(for: currentID) {
                currentRan.signal()
            }

            let currentCompleted = await currentRan.wait(timeout: .seconds(1))
            let staleCompleted = await staleRan.wait(timeout: .milliseconds(100))

            #expect(currentCompleted)
            #expect(!staleCompleted)
            #expect(coordinator.owns(currentID))
            coordinator.cancelCurrentOperation()
        }

        @Test("Cancellation cleanup runs only for cancelled operations")
        func cancellationCleanupRunsOnlyForCancelledOperations() {
            let coordinator = ImageGenerationCoordinator()
            var cleanupCount = 0

            let completedID = coordinator.beginOperation()
            coordinator.onCancel(for: completedID) {
                cleanupCount += 1
            }
            #expect(coordinator.finishOperation(completedID))
            coordinator.cancelCurrentOperation()
            #expect(cleanupCount == 0)

            let cancelledID = coordinator.beginOperation()
            coordinator.onCancel(for: cancelledID) {
                cleanupCount += 1
            }
            coordinator.cancelCurrentOperation()
            #expect(cleanupCount == 1)
        }

        @Test("Cancellation selects only responses that are still streaming")
        func cancellationSelectsOnlyStreamingResponses() {
            let userMessageID = UUID()
            let completedID = UUID()
            let streamingID = UUID()
            let failedID = UUID()
            let responseGroup = ResponseGroup(
                userMessageId: userMessageID,
                responses: [
                    .init(id: completedID, modelName: "completed", status: .completed),
                    .init(id: streamingID, modelName: "streaming", status: .streaming),
                    .init(id: failedID, modelName: "failed", status: .failed),
                ]
            )

            let pending = ImageGenerationCoordinator.pendingMessageIDs(
                in: responseGroup,
                candidates: [completedID, streamingID, failedID]
            )

            #expect(pending == [streamingID])
        }
    }
#endif
