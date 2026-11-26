import Foundation

final class UncheckedSendableWrapper<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

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

actor AsyncCompletionCounter {
    private var remaining: Int

    init(total: Int) {
        remaining = total
    }

    func decrementAndCheck() -> Bool {
        remaining -= 1
        return remaining <= 0
    }

    func getRemainingCount() -> Int {
        remaining
    }
}
