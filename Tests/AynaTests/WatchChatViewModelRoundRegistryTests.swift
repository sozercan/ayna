@testable import Ayna
import Foundation
import Testing

@Suite("Watch tool call round registry tests")
@MainActor
struct WatchToolCallRoundRegistryTests {
    @Test
    func `provider I ds deduplicate only within one request round`() {
        let providerID = "reused-call"
        let firstRound = WatchToolCallRoundRegistry(roundID: UUID())
        let secondRound = WatchToolCallRoundRegistry(roundID: UUID())

        #expect(firstRound.register(providerID: providerID, toolName: "tool", arguments: [:]) == providerID)
        #expect(firstRound.register(providerID: providerID, toolName: "tool", arguments: [:]) == nil)
        #expect(secondRound.register(providerID: providerID, toolName: "tool", arguments: [:]) == providerID)
    }

    @Test
    func `id less callbacks receive stable distinct round local I ds`() throws {
        let roundID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let registry = WatchToolCallRoundRegistry(roundID: roundID)
        let firstArguments = ["position": AnyCodable(1)]
        let secondArguments = ["position": AnyCodable(2)]

        let firstID = try #require(
            registry.register(providerID: "", toolName: "tool", arguments: firstArguments)
        )
        let secondID = try #require(
            registry.register(providerID: "   ", toolName: "tool", arguments: secondArguments)
        )
        #expect(registry.register(providerID: "", toolName: "tool", arguments: firstArguments) == nil)

        #expect(firstID == "watch-tool-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-0")
        #expect(secondID == "watch-tool-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-1")
        #expect(firstID != secondID)
    }
}
