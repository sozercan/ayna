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
    private let onDeliver: (String) -> Void

    // MARK: - Initialization

    init(config: Config = .default, onDeliver: @escaping (String) -> Void) {
        self.config = config
        self.onDeliver = onDeliver
    }

    deinit {
        deliveryTask?.cancel()
    }

    // MARK: - Public API

    /// Add a chunk to the buffer. May trigger immediate or delayed delivery.
    func append(_ chunk: String) {
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
    func flush() {
        deliveryTask?.cancel()
        deliveryTask = nil

        if !buffer.isEmpty {
            deliverNow()
        }
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
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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
/// Each model gets its own buffer to prevent interference.
@MainActor
final class MultiModelStreamingBuffer {
    private var buffers: [String: StreamingChunkBuffer] = [:]
    private let config: StreamingChunkBuffer.Config

    init(config: StreamingChunkBuffer.Config = .multiModel) {
        self.config = config
    }

    /// Get or create a buffer for a specific model
    func buffer(for model: String, onDeliver: @escaping (String) -> Void) -> StreamingChunkBuffer {
        if let existing = buffers[model] {
            return existing
        }

        let newBuffer = StreamingChunkBuffer(config: config, onDeliver: onDeliver)
        buffers[model] = newBuffer
        return newBuffer
    }

    /// Flush all buffers
    func flushAll() {
        for buffer in buffers.values {
            buffer.flush()
        }
    }

    /// Reset all buffers
    func resetAll() {
        for buffer in buffers.values {
            buffer.reset()
        }
        buffers.removeAll()
    }

    /// Reset buffer for a specific model
    func reset(for model: String) {
        buffers[model]?.reset()
        buffers.removeValue(forKey: model)
    }
}
