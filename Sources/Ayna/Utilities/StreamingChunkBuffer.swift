//
//  StreamingChunkBuffer.swift
//  ayna
//
//  Created on 12/1/25.
//

import Foundation

/// A thread-safe buffer that accumulates streaming chunks and delivers them
/// in batches to reduce main thread pressure during rapid streaming.
///
/// Use this when receiving rapid SSE chunks that would otherwise cause
/// UI stuttering from too-frequent updates.
@MainActor
final class StreamingChunkBuffer {
    // MARK: - Configuration

    struct Config {
        /// Minimum time between deliveries (in seconds)
        let minDeliveryInterval: TimeInterval
        /// Maximum buffer size before forcing immediate delivery
        let maxBufferSize: Int
        /// Maximum time to wait before forcing delivery (even with small buffer)
        let maxWaitTime: TimeInterval

        static let `default` = Config(
            minDeliveryInterval: 0.05, // 50ms = ~20 updates/second max
            maxBufferSize: 100, // Force delivery if buffer exceeds 100 chars
            maxWaitTime: 0.2 // Force delivery after 200ms regardless
        )

        /// More aggressive throttling for multi-model scenarios
        static let multiModel = Config(
            minDeliveryInterval: 0.1, // 100ms = ~10 updates/second max
            maxBufferSize: 200, // Larger buffer for multi-model
            maxWaitTime: 0.3
        )
    }

    // MARK: - State

    private var buffer: String = ""
    private var lastDeliveryTime: Date = .distantPast
    private var firstChunkTime: Date?
    private var deliveryTask: Task<Void, Never>?
    private let config: Config

    /// Callback for delivering accumulated chunks
    fileprivate var onDeliver: (String) -> Void

    // MARK: - Initialization

    init(config: Config? = nil, onDeliver: @escaping (String) -> Void) {
        self.config = config ?? .default
        self.onDeliver = onDeliver
    }

    deinit {
        deliveryTask?.cancel()
    }

    // MARK: - Public API

    /// Add a chunk to the buffer. May trigger immediate or delayed delivery.
    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        buffer += chunk

        // Track when we received the first chunk in this batch
        if firstChunkTime == nil {
            firstChunkTime = Date()
        }

        // Check if we should deliver immediately
        if shouldDeliverImmediately() {
            deliverNow()
        } else if deliveryTask == nil {
            // Schedule a delivery if none is pending
            scheduleDelivery()
        }
    }

    /// Force delivery of any remaining buffered content.
    /// Call this when streaming completes.
    @discardableResult
    func flush() -> Bool {
        deliveryTask?.cancel()
        deliveryTask = nil

        guard !buffer.isEmpty else { return false }
        deliverNow()
        return true
    }

    /// Cancel any pending delivery and clear the buffer.
    func reset() {
        deliveryTask?.cancel()
        deliveryTask = nil
        buffer = ""
        firstChunkTime = nil
    }

    // MARK: - Private Methods

    private func shouldDeliverImmediately() -> Bool {
        // Deliver immediately if buffer is too large
        if buffer.count >= config.maxBufferSize {
            return true
        }

        // Deliver immediately if we've been waiting too long
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

// MARK: - Multi-Model Buffer Manager

/// Manages multiple buffers for multi-model streaming scenarios.
/// Each response message gets its own buffer to prevent interference.
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

    /// Get or create a buffer for a specific response message.
    func buffer(for messageID: UUID, onDeliver: @escaping (String) -> Void) -> StreamingChunkBuffer {
        if let existing = buffers[messageID] {
            existing.onDeliver = onDeliver
            return existing
        }

        let newBuffer = StreamingChunkBuffer(config: config, onDeliver: onDeliver)
        buffers[messageID] = newBuffer
        return newBuffer
    }

    /// Flush all buffers without ending their streams.
    @discardableResult
    func flushAll() -> Bool {
        var delivered = false
        for buffer in buffers.values {
            delivered = buffer.flush() || delivered
        }
        return delivered
    }

    /// Flush and remove a completed response buffer.
    @discardableResult
    func finish(for messageID: UUID) -> Bool {
        guard let buffer = buffers.removeValue(forKey: messageID) else { return false }
        return buffer.flush()
    }

    /// Flush and remove every response buffer owned by the current operation.
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

    /// Reset all buffers.
    func resetAll() {
        for buffer in buffers.values {
            buffer.reset()
        }
        buffers.removeAll()
    }

    /// Reset a response buffer without delivering it.
    func reset(for messageID: UUID) {
        buffers[messageID]?.reset()
        buffers.removeValue(forKey: messageID)
    }
}
