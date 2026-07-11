@testable import Ayna
import Foundation
import Testing

// swiftformat:disable swiftTestingTestCaseNames

@Suite("MultiModelRequestRunner Tests", .tags(.async), .serialized, .timeLimit(.minutes(1)))
@MainActor
struct MultiModelRequestRunnerTests {
    @Test("Synchronous duplicate completion resumes and releases exactly once")
    func synchronousDuplicateCompletionResumesAndReleasesExactlyOnce() async {
        let startCount = FlightTestBox(0)
        let releaseCount = FlightTestBox(0)
        let permit = MultiModelRequestRunner.GitHubPermit(
            acquire: {},
            release: { releaseCount.update { $0 += 1 } }
        )

        await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
            startCount.value += 1
            completion()
            completion()
        }

        #expect(startCount.value == 1)
        #expect(releaseCount.value == 1)
    }

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

    @Test("Same-key GitHub permits serialize request starts")
    func sameKeyGitHubPermitsSerializeStarts() async {
        let queued = FlightTestSignal()
        let gate = DeterministicGitHubGate(queued: queued)
        let permit = makePermit(gate: gate, key: "same-token")
        let firstStarted = FlightTestSignal()
        let secondStarted = FlightTestSignal()
        let firstCompletion = FlightTestBox<MultiModelRequestRunner.Completion?>(nil)
        let secondCompletion = FlightTestBox<MultiModelRequestRunner.Completion?>(nil)

        let first = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
                firstCompletion.value = completion
                firstStarted.signal()
            }
        }
        await firstStarted.wait()

        let second = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
                secondCompletion.value = completion
                secondStarted.signal()
            }
        }
        await queued.wait()
        #expect(!secondStarted.isSignaled)

        firstCompletion.value?()
        await secondStarted.wait()
        secondCompletion.value?()
        await first.value
        await second.value

        #expect(await gate.releaseCount == 2)
    }

    @Test("Cancellation releases a held GitHub permit")
    func cancellationReleasesHeldGitHubPermit() async {
        let queued = FlightTestSignal()
        let gate = DeterministicGitHubGate(queued: queued)
        let permit = makePermit(gate: gate, key: "same-token")
        let firstStarted = FlightTestSignal()
        let secondStarted = FlightTestSignal()
        let secondCompletion = FlightTestBox<MultiModelRequestRunner.Completion?>(nil)

        let first = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { _ in
                firstStarted.signal()
            }
        }
        await firstStarted.wait()

        let second = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
                secondCompletion.value = completion
                secondStarted.signal()
            }
        }
        await queued.wait()

        first.cancel()
        await secondStarted.wait()
        secondCompletion.value?()
        await first.value
        await second.value

        #expect(await gate.releaseCount == 2)
    }

    @Test("Cancellation while queued never starts or releases an unacquired permit")
    func cancellationWhileQueuedNeverStartsOrReleasesUnacquiredPermit() async {
        let queued = FlightTestSignal()
        let gate = DeterministicGitHubGate(queued: queued)
        let permit = makePermit(gate: gate, key: "same-token")
        let firstStarted = FlightTestSignal()
        let cancelledStarted = FlightTestSignal()
        let replacementStarted = FlightTestSignal()
        let firstCompletion = FlightTestBox<MultiModelRequestRunner.Completion?>(nil)
        let replacementCompletion = FlightTestBox<MultiModelRequestRunner.Completion?>(nil)

        let first = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
                firstCompletion.value = completion
                firstStarted.signal()
            }
        }
        await firstStarted.wait()

        let cancelled = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
                cancelledStarted.signal()
                completion()
            }
        }
        await queued.wait()
        cancelled.cancel()
        await cancelled.value
        #expect(!cancelledStarted.isSignaled)

        firstCompletion.value?()
        await first.value

        let replacement = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
                replacementCompletion.value = completion
                replacementStarted.signal()
            }
        }
        await replacementStarted.wait()
        replacementCompletion.value?()
        await replacement.value

        #expect(await gate.releaseCount == 2)
    }

    @Test("Cancellation after permit acquisition releases without starting")
    func cancellationAfterPermitAcquisitionReleasesWithoutStarting() async {
        let started = FlightTestSignal()
        let releaseCount = FlightTestBox(0)
        let permit = MultiModelRequestRunner.GitHubPermit(
            acquire: {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
            },
            release: { releaseCount.update { $0 += 1 } }
        )

        let task = Task { @MainActor in
            await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
                started.signal()
                completion()
            }
        }
        await task.value

        #expect(!started.isSignaled)
        #expect(releaseCount.value == 1)
    }

    @Test("Failed permit acquisition neither starts nor releases")
    func failedPermitAcquisitionNeitherStartsNorReleases() async {
        let started = FlightTestSignal()
        let releaseCount = FlightTestBox(0)
        let permit = MultiModelRequestRunner.GitHubPermit(
            acquire: { throw RunnerTestError.expected },
            release: { releaseCount.update { $0 += 1 } }
        )

        await MultiModelRequestRunner.run(gitHubPermit: permit) { completion in
            started.signal()
            completion()
        }

        #expect(!started.isSignaled)
        #expect(releaseCount.value == 0)
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

    private func makePermit(
        gate: DeterministicGitHubGate,
        key: String
    ) -> MultiModelRequestRunner.GitHubPermit {
        MultiModelRequestRunner.GitHubPermit(
            acquire: { try await gate.acquire(key: key) },
            release: { await gate.release(key: key) }
        )
    }
}

private enum RunnerTestError: Error {
    case expected
}

private actor DeterministicGitHubGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var activeKeys: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]
    private let queued: FlightTestSignal
    private(set) var releaseCount = 0

    init(queued: FlightTestSignal) {
        self.queued = queued
    }

    func acquire(key: String) async throws {
        try Task.checkCancellation()
        guard activeKeys.contains(key) else {
            activeKeys.insert(key)
            return
        }

        let id = UUID()
        queued.signal()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[key, default: []].append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(key: key, id: id) }
        }
    }

    func release(key: String) {
        releaseCount += 1
        guard var queue = waiters[key], !queue.isEmpty else {
            waiters[key] = nil
            activeKeys.remove(key)
            return
        }

        let next = queue.removeFirst()
        waiters[key] = queue.isEmpty ? nil : queue
        next.continuation.resume()
    }

    private func cancelWaiter(key: String, id: UUID) {
        guard var queue = waiters[key],
              let index = queue.firstIndex(where: { $0.id == id })
        else {
            return
        }

        let waiter = queue.remove(at: index)
        waiters[key] = queue.isEmpty ? nil : queue
        waiter.continuation.resume(throwing: CancellationError())
    }
}
