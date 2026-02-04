//
//  AsyncCompletionTracker.swift
//  ayna
//
//  Shared utilities for tracking async completion and thread-safe wrappers
//

import Foundation

/// A wrapper to make non-Sendable types Sendable by unchecked conformance.
/// Use this only when you are sure the value is thread-safe or accessed safely.
final class UncheckedSendableWrapper<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

/// Thread-safe counter for tracking async completion using MainActor
@MainActor
final class MainActorCompletionCounter {
    private var completed: Int = 0
    private let total: Int

    init(total: Int) {
        self.total = total
    }

    func increment() {
        completed += 1
    }

    var isComplete: Bool {
        completed >= total
    }

    var remaining: Int {
        max(0, total - completed)
    }
}

/// Actor-based counter for truly concurrent access patterns
actor AsyncCompletionCounter {
    private var remaining: Int

    init(total: Int) {
        remaining = total
    }

    /// Decrements and returns true if all completions are done
    func decrementAndCheck() -> Bool {
        remaining -= 1
        return remaining <= 0
    }

    /// Returns current remaining count
    func getRemainingCount() -> Int {
        remaining
    }
}
