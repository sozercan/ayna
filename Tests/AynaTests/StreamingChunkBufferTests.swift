@testable import Ayna
import Foundation
import Testing

@Suite("Streaming Chunk Buffer Tests", .tags(.fast, .async))
@MainActor
struct StreamingChunkBufferTests {
    private let deferredConfig = StreamingChunkBuffer.Config(
        minDeliveryInterval: 60,
        maxBufferSize: 1000,
        maxWaitTime: 60
    )

    @Test
    func `threshold delivers accumulated chunks immediately`() {
        var deliveries: [String] = []
        let buffer = StreamingChunkBuffer(
            config: .init(minDeliveryInterval: 60, maxBufferSize: 4, maxWaitTime: 60)
        ) { deliveries.append($0) }

        buffer.append("ab")
        #expect(deliveries.isEmpty)

        buffer.append("cd")
        #expect(deliveries == ["abcd"])
    }

    @Test(.timeLimit(.minutes(1)))
    func `scheduled delivery flushes a small chunk`() async {
        var deliveries: [String] = []
        let delivered = FlightTestSignal()
        let buffer = StreamingChunkBuffer(
            config: .init(minDeliveryInterval: 0.01, maxBufferSize: 1000, maxWaitTime: 60)
        ) {
            deliveries.append($0)
            delivered.signal()
        }

        buffer.append("delayed")
        #expect(deliveries.isEmpty)

        #expect(await delivered.wait(timeout: .seconds(1)))
        #expect(deliveries == ["delayed"])
    }

    @Test
    func `finish isolates messages flushes once and removes the completed buffer`() {
        let firstID = UUID()
        let secondID = UUID()
        let buffers = MultiModelStreamingBuffer(config: deferredConfig)
        var deliveries: [UUID: String] = [:]

        buffers.buffer(for: firstID) { deliveries[firstID, default: ""] += $0 }.append("first-")
        buffers.buffer(for: firstID) { deliveries[firstID, default: ""] += $0 }.append("response")
        buffers.buffer(for: secondID) { deliveries[secondID, default: ""] += $0 }.append("second")

        #expect(deliveries.isEmpty)
        #expect(buffers.finish(for: firstID))
        #expect(deliveries[firstID] == "first-response")
        #expect(deliveries[secondID] == nil)
        #expect(!buffers.isEmpty)
        #expect(!buffers.finish(for: firstID))

        #expect(buffers.finishAll())
        #expect(deliveries[secondID] == "second")
        #expect(buffers.isEmpty)
        #expect(!buffers.finishAll())
    }

    @Test(.timeLimit(.minutes(1)))
    func `reset drops pending data and cancels scheduled delivery`() async {
        let messageID = UUID()
        let buffers = MultiModelStreamingBuffer(
            config: .init(minDeliveryInterval: 0.01, maxBufferSize: 1000, maxWaitTime: 60)
        )
        var deliveries: [String] = []

        buffers.buffer(for: messageID) { deliveries.append($0) }.append("discard me")
        buffers.reset(for: messageID)

        try? await Task.sleep(for: .milliseconds(50))
        #expect(deliveries.isEmpty)
        #expect(buffers.isEmpty)
    }
}
