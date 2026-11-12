// swiftlint:disable identifier_name
@testable import Ayna
import Combine
import Foundation
import Testing

@Suite("Streaming update cost", .serialized)
@MainActor
struct StreamingUpdateCostTests {
    @Test
    func `Appending a streamed chunk publishes one change`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let manager = ConversationManager(
            store: TestHelpers.makeTestStore(directory: directory),
            saveDebounceDuration: .milliseconds(0),
            searchIndexWarmupEnabled: false
        )
        _ = await manager.loadingTask?.value
        let conversation = TestHelpers.sampleConversation(title: "Streaming")
        manager.conversations.insert(conversation, at: 0)
        let assistant = try #require(conversation.messages.last)

        var publications = 0
        let subscription = manager.$conversations.dropFirst().sink { _ in publications += 1 }
        defer { subscription.cancel() }

        #expect(manager.appendToMessage(conversationId: conversation.id, messageId: assistant.id, chunk: " more"))

        #expect(publications == 1)
        #expect(manager.conversations.first?.messages.last?.content == "Hi there more")
    }
}

// swiftlint:enable identifier_name
