@testable import Ayna
import Foundation
import Testing

@Suite("Ordered Async Operation Queue Tests")
struct OrderedAsyncOperationQueueTests {
    @Test
    func `clear cleanup stays between prior and subsequent indexing`() async {
        let queue = OrderedAsyncOperationQueue()
        let gate = OrderedOperationGate()
        let recorder = OrderedOperationRecorder()

        queue.enqueue {
            await recorder.append("old-index-start")
            await gate.wait()
            await recorder.append("old-index-finish")
        }
        await gate.waitUntilStarted()

        queue.enqueue {
            await recorder.append("clear")
        }
        queue.enqueue {
            await recorder.append("new-index")
        }

        #expect(await recorder.values() == ["old-index-start"])
        await gate.release()
        await queue.waitForAll()

        #expect(await recorder.values() == [
            "old-index-start",
            "old-index-finish",
            "clear",
            "new-index",
        ])
    }
}

private actor OrderedOperationGate {
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()
        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        for continuation in releaseContinuations {
            continuation.resume()
        }
        releaseContinuations.removeAll()
    }
}

private actor OrderedOperationRecorder {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func values() -> [String] {
        recordedValues
    }
}
