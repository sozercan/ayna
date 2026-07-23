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

        #expect(owner.count == 0)
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

        #expect(owner.count == 0)
        #expect(first.cancelCount == 1)
        #expect(second.cancelCount == 1)
    }
}

@MainActor
private final class FakeProvider: AIProviderProtocol, @unchecked Sendable {
    let providerType: AIProvider = .openai
    let requiresAPIKey = true
    var cancelCount = 0

    func sendMessage(
        messages _: [Message],
        config _: AIProviderRequestConfig,
        stream _: Bool,
        tools _: [[String: Any]]?,
        callbacks _: AIProviderStreamCallbacks
    ) {}

    func cancelRequest() {
        cancelCount += 1
    }
}
