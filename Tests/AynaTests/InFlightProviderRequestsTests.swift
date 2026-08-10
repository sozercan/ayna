@testable import Ayna
import Foundation
import Testing

@Suite("InFlightProviderRequests Tests", .tags(.fast))
@MainActor
struct InFlightProviderRequestsTests {
    @Test("Retains multiple providers independently and releases by lease")
    func retainsMultipleProvidersIndependently() {
        let owner = InFlightProviderRequests()
        let first = FakeProvider()
        let second = FakeProvider()

        let firstLease = owner.retain(first)
        _ = owner.retain(second)

        #expect(owner.count == 2)
        firstLease.release()
        #expect(owner.count == 1)
        #expect(first.cancelCount == 0)
        #expect(second.cancelCount == 0)
    }

    @Test("Release is idempotent")
    func releaseIsIdempotent() {
        let owner = InFlightProviderRequests()
        let provider = FakeProvider()
        let lease = owner.retain(provider)

        lease.release()
        lease.release()

        #expect(owner.count == Int.zero)
        #expect(provider.cancelCount == 0)
    }

    @Test("Cancel all cancels every retained provider once and clears ownership")
    func cancelAllCancelsEveryProviderOnceAndClearsOwnership() {
        let owner = InFlightProviderRequests()
        let first = FakeProvider()
        let second = FakeProvider()
        let firstLease = owner.retain(first)
        _ = owner.retain(second)

        owner.cancelAll()
        firstLease.release()

        #expect(owner.count == Int.zero)
        #expect(first.cancelCount == 1)
        #expect(second.cancelCount == 1)
    }

    @Test("Cancel all invokes each cancellation terminal once")
    func cancelAllInvokesEachCancellationTerminalOnce() {
        let owner = InFlightProviderRequests()
        let provider = FakeProvider()
        var cancellationCount = 0
        _ = owner.retain(provider, onCancel: {
            cancellationCount += 1
        })

        owner.cancelAll()
        owner.cancelAll()

        #expect(cancellationCount == 1)
        #expect(provider.cancelCount == 1)
    }

    @Test("Cancellation terminal wins before provider cancellation callbacks")
    func cancellationTerminalWinsBeforeProviderCancellationCallbacks() {
        let owner = InFlightProviderRequests()
        let provider = FakeProvider()
        let terminal = ProviderRequestTerminal()
        let cancellationCount = LockedCounter()
        let completionCount = LockedCounter()

        terminal.setCancellationAction {
            cancellationCount.increment()
        }
        provider.onCancel = {
            terminal.complete {
                completionCount.increment()
            }
        }
        _ = owner.retain(provider, onCancel: {
            terminal.cancel()
        })

        owner.cancelAll()

        #expect(cancellationCount.value == 1)
        #expect(completionCount.value == 0)
        #expect(provider.cancelCount == 1)
    }

    @Test("Provider terminal resumes once when cancelled before continuation installation")
    func providerTerminalResumesOnceWhenCancelledBeforeContinuationInstallation() async {
        let terminal = ProviderRequestTerminal()
        let cancellationCount = LockedCounter()
        let resumeCount = LockedCounter()
        let completionCount = LockedCounter()

        terminal.setCancellationAction {
            cancellationCount.increment()
        }
        terminal.cancel()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            terminal.install(continuation)
        }
        resumeCount.increment()

        terminal.cancel()
        terminal.complete {
            completionCount.increment()
        }

        #expect(cancellationCount.value == 1)
        #expect(resumeCount.value == 1)
        #expect(completionCount.value == 0)
    }
}

@MainActor
private final class FakeProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .openai
    let requiresAPIKey = true
    var cancelCount = 0
    var onCancel: (@MainActor () -> Void)?

    func sendMessage(
        messages _: [Message],
        config _: AIProviderRequestConfig,
        stream _: Bool,
        tools _: [[String: Any]]?,
        callbacks _: AIProviderStreamCallbacks
    ) {}

    func cancelRequest() {
        cancelCount += 1
        onCancel?()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}
