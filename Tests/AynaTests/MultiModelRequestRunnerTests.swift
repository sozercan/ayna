@testable import Ayna
import Foundation
import Testing

// swiftformat:disable swiftTestingTestCaseNames

@Suite("MultiModelRequestRunner Tests", .tags(.async), .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MultiModelRequestRunnerTests {
    @Test("Cancellation resumes a request that never calls back")
    func cancellationResumesRequestWithoutCallback() async {
        let started = FlightTestSignal()
        let task = Task { @MainActor in
            await MultiModelRequestRunner.run { _ in
                started.signal()
            }
        }

        await started.wait()
        task.cancel()
        await task.value

        #expect(started.isSignaled)
    }

    @Test("Completion retained by a cancelled request is harmless")
    func retainedCompletionAfterCancellationIsHarmless() async {
        let started = FlightTestSignal()
        let retainedCompletion = FlightTestBox<MultiModelRequestRunner.Completion?>(nil)
        let task = Task { @MainActor in
            await MultiModelRequestRunner.run { completion in
                retainedCompletion.value = completion
                started.signal()
            }
        }

        await started.wait()
        task.cancel()
        await task.value
        retainedCompletion.value?()
        retainedCompletion.value?()

        #expect(started.isSignaled)
    }

    @Test("A pre-cancelled task never starts its request")
    func preCancelledTaskNeverStartsRequest() async {
        let started = FlightTestSignal()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { currentTask in
                currentTask?.cancel()
            }
            await MultiModelRequestRunner.run { completion in
                started.signal()
                completion()
            }
        }

        await task.value

        #expect(!started.isSignaled)
    }

    @Test("Cancellation while start is invoking terminates the runner")
    func cancellationWhileStartIsInvokingTerminatesRunner() async {
        let returned = FlightTestSignal()

        let task = Task { @MainActor in
            await MultiModelRequestRunner.run { _ in
                withUnsafeCurrentTask { currentTask in
                    currentTask?.cancel()
                }
            }
            returned.signal()
        }

        #expect(await returned.wait(timeout: .seconds(2)))
        await task.value
    }
}
