@testable import Ayna
import Foundation
import Testing

#if os(iOS)
    @Suite("IOSChatViewModel Streaming Coalescing Tests", .tags(.viewModel, .async))
    @MainActor
    struct IOSChatViewModelStreamingCoalescingTests {
        private struct Fixture {
            let viewModel: IOSChatViewModel
            let manager: ConversationManager
            let conversationId: UUID
            let messageId: UUID
            let responseGroupId: UUID
            let model: String
            let messageIds: [String: UUID]
        }

        private let defaults: UserDefaults

        init() {
            guard let suite = UserDefaults(suiteName: "IOSChatViewModelStreamingCoalescingTests") else {
                fatalError("Failed to create UserDefaults suite for tests")
            }
            defaults = suite
            defaults.removePersistentDomain(forName: "IOSChatViewModelStreamingCoalescingTests")
            AppPreferences.use(defaults)
            defaults.set(false, forKey: "autoGenerateTitle")
            AIService.keychain = InMemoryKeychainStorage()
        }

        @Test("Multi-model chunks wait for coalescing interval before mutating conversation", .timeLimit(.minutes(1)))
        func multiModelChunksAreCoalescedBeforeMutation() async throws {
            let fixture = try await makeFixture()

            fixture.viewModel.processMultiModelChunk(
                model: fixture.model,
                chunk: "Hel",
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId
            )
            fixture.viewModel.processMultiModelChunk(
                model: fixture.model,
                chunk: "lo",
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId
            )

            #expect(fixture.manager.conversations.first?.messages.first?.content == "")
            #expect(fixture.viewModel.messageContentRevision == 0)

            try await Task.sleep(for: .milliseconds(120))

            #expect(fixture.manager.conversations.first?.messages.first?.content == "Hello")
            #expect(fixture.manager.conversations.first?.messages.last?.content == "")
            #expect(fixture.viewModel.messageContentRevision == 1)
        }

        @Test("Model completion flushes pending chunks immediately", .timeLimit(.minutes(1)))
        func modelCompletionFlushesPendingChunksImmediately() async throws {
            let fixture = try await makeFixture()

            fixture.viewModel.processMultiModelChunk(
                model: fixture.model,
                chunk: "Done",
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId
            )
            #expect(fixture.manager.conversations.first?.messages.first?.content == "")

            fixture.viewModel.processMultiModelCompletion(
                model: fixture.model,
                messageIds: fixture.messageIds,
                conversationId: fixture.conversationId,
                responseGroupId: fixture.responseGroupId
            )

            #expect(fixture.manager.conversations.first?.messages.first?.content == "Done")
            #expect(fixture.manager.conversations.first?.responseGroups.first?.responses.first?.status == .completed)
            #expect(fixture.viewModel.messageContentRevision == 1)
        }

        private func makeFixture() async throws -> Fixture {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let store = TestHelpers.makeTestStore(directory: directory, keychain: InMemoryKeychainStorage())
            let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
            _ = await manager.loadingTask?.value

            let conversationId = UUID()
            let messageId = UUID()
            let responseGroupId = UUID()
            let userMessageId = UUID()
            let model = "test-model-a"
            let trailingModel = "test-model-b"
            let trailingMessageId = UUID()
            var responseGroup = ResponseGroup(id: responseGroupId, userMessageId: userMessageId)
            responseGroup.addResponse(messageId: messageId, modelName: model, status: .streaming)
            responseGroup.addResponse(messageId: trailingMessageId, modelName: trailingModel, status: .streaming)
            let assistantMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId
            )
            let trailingAssistantMessage = Message(
                id: trailingMessageId,
                role: .assistant,
                content: "",
                model: trailingModel,
                responseGroupId: responseGroupId
            )
            let conversation = Conversation(
                id: conversationId,
                title: "Streaming Coalescing",
                messages: [assistantMessage, trailingAssistantMessage],
                model: model,
                responseGroups: [responseGroup]
            )
            manager.conversations = [conversation]

            let service = AIService(urlSession: URLSession(configuration: .ephemeral))
            let viewModel = IOSChatViewModel(
                conversationId: conversationId,
                conversationManager: manager,
                aiService: service
            )

            return Fixture(
                viewModel: viewModel,
                manager: manager,
                conversationId: conversationId,
                messageId: messageId,
                responseGroupId: responseGroupId,
                model: model,
                messageIds: [model: messageId]
            )
        }
    }
#endif
