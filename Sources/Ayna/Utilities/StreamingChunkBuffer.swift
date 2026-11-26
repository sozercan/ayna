import Foundation

@MainActor
final class StreamingChunkBuffer {
    struct Config {
        let minDeliveryInterval: TimeInterval
        let maxBufferSize: Int
        let maxWaitTime: TimeInterval

        static let `default` = Config(
            minDeliveryInterval: 0.05,
            maxBufferSize: 100,
            maxWaitTime: 0.2
        )

        static let multiModel = Config(
            minDeliveryInterval: 0.1,
            maxBufferSize: 200,
            maxWaitTime: 0.3
        )
    }

    private var buffer: String = ""
    private var lastDeliveryTime: Date = .distantPast
    private var firstChunkTime: Date?
    private var deliveryTask: Task<Void, Never>?
    private let config: Config

    fileprivate var onDeliver: (String) -> Void

    init(config: Config? = nil, onDeliver: @escaping (String) -> Void) {
        self.config = config ?? .default
        self.onDeliver = onDeliver
    }

    deinit {
        deliveryTask?.cancel()
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        buffer += chunk

        if firstChunkTime == nil {
            firstChunkTime = Date()
        }

        if shouldDeliverImmediately() {
            deliverNow()
        } else if deliveryTask == nil {
            scheduleDelivery()
        }
    }

    @discardableResult
    func flush() -> Bool {
        deliveryTask?.cancel()
        deliveryTask = nil

        guard !buffer.isEmpty else { return false }
        deliverNow()
        return true
    }

    func reset() {
        deliveryTask?.cancel()
        deliveryTask = nil
        buffer = ""
        firstChunkTime = nil
    }

    private func shouldDeliverImmediately() -> Bool {
        if buffer.count >= config.maxBufferSize {
            return true
        }

        if let firstChunk = firstChunkTime,
           Date().timeIntervalSince(firstChunk) >= config.maxWaitTime
        {
            return true
        }

        return false
    }

    private func scheduleDelivery() {
        let delay = config.minDeliveryInterval
        deliveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.deliverNow()
            }
        }
    }

    private func deliverNow() {
        deliveryTask?.cancel()
        deliveryTask = nil

        guard !buffer.isEmpty else { return }

        let content = buffer
        buffer = ""
        firstChunkTime = nil
        lastDeliveryTime = Date()

        onDeliver(content)
    }
}

@MainActor
final class MultiModelStreamingBuffer {
    private var buffers: [UUID: StreamingChunkBuffer] = [:]
    private let config: StreamingChunkBuffer.Config

    var isEmpty: Bool {
        buffers.isEmpty
    }

    init(config: StreamingChunkBuffer.Config? = nil) {
        self.config = config ?? .multiModel
    }

    func buffer(for messageID: UUID, onDeliver: @escaping (String) -> Void) -> StreamingChunkBuffer {
        if let existing = buffers[messageID] {
            existing.onDeliver = onDeliver
            return existing
        }

        let newBuffer = StreamingChunkBuffer(config: config, onDeliver: onDeliver)
        buffers[messageID] = newBuffer
        return newBuffer
    }

    @discardableResult
    func flushAll() -> Bool {
        var delivered = false
        for buffer in buffers.values {
            delivered = buffer.flush() || delivered
        }
        return delivered
    }

    @discardableResult
    func finish(for messageID: UUID) -> Bool {
        guard let buffer = buffers.removeValue(forKey: messageID) else { return false }
        return buffer.flush()
    }

    @discardableResult
    func finishAll() -> Bool {
        let activeBuffers = Array(buffers.values)
        buffers.removeAll()
        var delivered = false
        for buffer in activeBuffers {
            delivered = buffer.flush() || delivered
        }
        return delivered
    }

    func resetAll() {
        for buffer in buffers.values {
            buffer.reset()
        }
        buffers.removeAll()
    }

    func reset(for messageID: UUID) {
        buffers[messageID]?.reset()
        buffers.removeValue(forKey: messageID)
    }
}
