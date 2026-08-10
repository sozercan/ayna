@testable import Ayna
import Foundation
import Testing

@Suite("Conversation Manager Terminal Persistence", .tags(.viewModel, .persistence))
struct TerminalPersistenceTests {
    @MainActor
    private func makeEditingManager(
        store: EncryptedConversationStore,
        conversation: Conversation
    ) -> ConversationManager {
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .seconds(30),
            searchIndexWarmupEnabled: false,
            spotlightIndexingEnabled: false,
            startsLoadingImmediately: false
        )
        manager.conversations = [conversation]
        return manager
    }

    private func loadPersistedConversation(
        _ conversationID: UUID,
        from store: EncryptedConversationStore
    ) async throws -> Conversation {
        let conversation = try await store.loadConversation(id: conversationID)
        return try #require(conversation)
    }

    @Test
    @MainActor
    func `streaming mutations wait for an explicit terminal save point`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let assistant = Message(role: .assistant, content: "", model: AIService.shared.selectedModel)
        var original = Conversation(title: "Deferred stream", model: AIService.shared.selectedModel)
        original.addMessage(assistant)
        try await store.save(original)
        let manager = makeEditingManager(store: store, conversation: original)

        #expect(manager.appendToMessage(
            conversationId: original.id,
            messageId: assistant.id,
            chunk: "Hello"
        ))
        #expect(manager.updateMessage(conversationId: original.id, messageId: assistant.id) { message in
            message.reasoning = "Thinking"
        })

        await manager.flushPendingSaves()
        let beforeTerminalSave = try await loadPersistedConversation(original.id, from: store)
        let originalAssistant = try #require(beforeTerminalSave.messages.first(where: { $0.id == assistant.id }))
        #expect(originalAssistant.content.isEmpty)
        #expect(originalAssistant.reasoning == nil)

        #expect(manager.updateMessageAndPersist(
            conversationId: original.id,
            messageId: assistant.id
        ) { message in
            message.content += " world"
        })
        await manager.flushPendingSaves()

        let reloaded = try await loadPersistedConversation(original.id, from: store)
        let reloadedAssistant = try #require(reloaded.messages.first(where: { $0.id == assistant.id }))
        #expect(reloadedAssistant.content == "Hello world")
        #expect(reloadedAssistant.reasoning == "Thinking")
    }

    @Test
    @MainActor
    func `message removal survives reload`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let original = TestHelpers.sampleConversation(
            title: "Remove terminal placeholder",
            model: AIService.shared.selectedModel
        )
        let removedMessageID = try #require(original.messages.last?.id)
        try await store.save(original)
        let manager = makeEditingManager(store: store, conversation: original)

        #expect(manager.removeMessage(
            conversationId: original.id,
            messageId: removedMessageID
        ))
        await manager.flushPendingSaves()

        let reloaded = try await loadPersistedConversation(original.id, from: store)
        #expect(!reloaded.messages.contains(where: { $0.id == removedMessageID }))
    }

    @Test
    @MainActor
    func `terminal response status persists accumulated chunks`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        let groupID = UUID()
        let user = Message(role: .user, content: "Compare")
        let assistant = Message(
            role: .assistant,
            content: "",
            model: AIService.shared.selectedModel,
            responseGroupId: groupID
        )
        let responseGroup = ResponseGroup(
            id: groupID,
            userMessageId: user.id,
            responses: [
                .init(id: assistant.id, modelName: AIService.shared.selectedModel, status: .streaming),
            ]
        )
        var original = Conversation(
            title: "Terminal response group",
            messages: [user, assistant],
            model: AIService.shared.selectedModel,
            responseGroups: [responseGroup]
        )
        original.updatedAt = Date()
        try await store.save(original)
        let manager = makeEditingManager(store: store, conversation: original)

        #expect(manager.appendToMessage(
            conversationId: original.id,
            messageId: assistant.id,
            chunk: "Completed response"
        ))
        #expect(!manager.updateResponseGroupStatus(
            conversationId: original.id,
            responseGroupId: groupID,
            messageId: UUID(),
            status: .completed
        ))
        #expect(manager.updateResponseGroupStatus(
            conversationId: original.id,
            responseGroupId: groupID,
            messageId: assistant.id,
            status: .completed
        ))
        await manager.flushPendingSaves()

        let reloaded = try await loadPersistedConversation(original.id, from: store)
        let reloadedAssistant = try #require(reloaded.messages.first(where: { $0.id == assistant.id }))
        let reloadedGroup = try #require(reloaded.getResponseGroup(groupID))
        #expect(reloadedAssistant.content == "Completed response")
        #expect(reloadedGroup.responses.first?.status == .completed)
    }
}
