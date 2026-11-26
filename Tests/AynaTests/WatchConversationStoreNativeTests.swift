#if os(watchOS)

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("WatchConversationStore Native Tests")
    @MainActor
    struct WatchConversationStoreNativeTests {
        private let userDefaults: UserDefaults
        private let persistenceKey: String
        private let store: WatchConversationStore

        init() {
            let suiteName = "WatchConversationStoreNativeTests.\(UUID().uuidString)"
            guard let userDefaults = UserDefaults(suiteName: suiteName) else {
                fatalError("Failed to create isolated UserDefaults suite")
            }
            userDefaults.removePersistentDomain(forName: suiteName)

            let persistenceKey = "state"
            self.userDefaults = userDefaults
            self.persistenceKey = persistenceKey
            store = WatchConversationStore(
                userDefaults: userDefaults,
                persistenceKey: persistenceKey,
                mutationEnqueuer: { _ in }
            )
        }

        @Test
        func `create conversation with title and model`() throws {
            let conversation = try #require(store.createConversation(title: "Test Chat", model: "gpt-4o"))

            #expect(conversation.title == "Test Chat")
            #expect(conversation.model == "gpt-4o")
            #expect(conversation.messages.isEmpty)
            #expect(store.conversations.contains { $0.id == conversation.id })
        }

        @Test
        func `create conversation with default title`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4"))

            #expect(conversation.title == "New Chat")
            #expect(conversation.model == "gpt-4")
        }

        @Test
        func `new conversation appears first`() async throws {
            let first = try #require(store.createConversation(model: "gpt-4o"))

            try? await Task.sleep(for: .milliseconds(100))

            let second = try #require(store.createConversation(model: "gpt-4"))

            #expect(store.conversations.first?.id == second.id)
            #expect(store.conversations.contains { $0.id == first.id })
        }

        @Test
        func `add message to conversation`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            let message = WatchMessage(from: Message(role: .user, content: "Hello"))

            store.addMessage(message, to: conversation.id)

            let updated = store.conversation(for: conversation.id)
            #expect(updated?.messages.count == 1)
            #expect(updated?.messages.first?.content == "Hello")
            #expect(updated?.messages.first?.role == "user")
        }

        @Test
        func `add multiple messages`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))

            let userMessage = WatchMessage(from: Message(role: .user, content: "Hi"))
            let assistantMessage = WatchMessage(from: Message(role: .assistant, content: "Hello!"))

            store.addMessage(userMessage, to: conversation.id)
            store.addMessage(assistantMessage, to: conversation.id)

            let updated = store.conversation(for: conversation.id)
            #expect(updated?.messages.count == 2)
            #expect(updated?.messages[0].role == "user")
            #expect(updated?.messages[1].role == "assistant")
        }

        @Test
        func `update last message`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            let message = WatchMessage(from: Message(role: .assistant, content: ""))

            store.addMessage(message, to: conversation.id)
            store.updateLastMessage(in: conversation.id, content: "Streaming content...")

            let updated = store.conversation(for: conversation.id)
            #expect(updated?.messages.last?.content == "Streaming content...")
        }

        @Test
        func `update last message streaming`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            let message = WatchMessage(from: Message(role: .assistant, content: ""))

            store.addMessage(message, to: conversation.id)

            store.updateLastMessage(in: conversation.id, content: "Hello")
            store.updateLastMessage(in: conversation.id, content: "Hello, ")
            store.updateLastMessage(in: conversation.id, content: "Hello, World!")

            let updated = store.conversation(for: conversation.id)
            #expect(updated?.messages.last?.content == "Hello, World!")
        }

        @Test
        func `update last message persists streamed content`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            let message = WatchMessage(from: Message(role: .assistant, content: ""))

            store.addMessage(message, to: conversation.id)
            store.updateLastMessage(in: conversation.id, content: "Persist me")

            let reloadedStore = WatchConversationStore(
                userDefaults: userDefaults,
                persistenceKey: persistenceKey,
                mutationEnqueuer: { _ in }
            )
            let persistedConversation = reloadedStore.conversation(for: conversation.id)
            #expect(persistedConversation?.messages.last?.content == "Persist me")
        }

        @Test
        func `get conversation for valid ID`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))

            let retrieved = store.conversation(for: conversation.id)

            #expect(retrieved != nil)
            #expect(retrieved?.id == conversation.id)
        }

        @Test
        func `get conversation for invalid ID returns nil`() {
            let randomId = UUID()
            let retrieved = store.conversation(for: randomId)

            #expect(retrieved == nil)
        }

        @Test
        func `preview text with messages`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            let message = WatchMessage(from: Message(role: .assistant, content: "This is a response"))

            store.addMessage(message, to: conversation.id)

            if let updated = store.conversation(for: conversation.id) {
                let preview = store.previewText(for: updated)
                #expect(preview == "This is a response")
            } else {
                Issue.record("Conversation should exist")
            }
        }

        @Test
        func `preview text with long message truncates`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            let longContent = String(repeating: "A", count: 100)
            let message = WatchMessage(from: Message(role: .assistant, content: longContent))

            store.addMessage(message, to: conversation.id)

            if let updated = store.conversation(for: conversation.id) {
                let preview = store.previewText(for: updated)
                #expect(preview.count <= 53)
                #expect(preview.hasSuffix("..."))
            } else {
                Issue.record("Conversation should exist")
            }
        }

        @Test
        func `preview text for empty conversation`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))

            let preview = store.previewText(for: conversation)
            #expect(preview == "No messages")
        }

        @Test
        func `delete conversation`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            #expect(store.conversations.contains { $0.id == conversation.id })

            store.deleteConversation(conversation.id)

            #expect(!store.conversations.contains { $0.id == conversation.id })
            #expect(store.conversation(for: conversation.id) == nil)
        }

        @Test
        func `delete conversation clears selection`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            store.selectedConversationId = conversation.id

            store.deleteConversation(conversation.id)

            #expect(store.selectedConversationId == nil)
        }

        @Test
        func `rename conversation`() throws {
            let conversation = try #require(store.createConversation(title: "Original", model: "gpt-4o"))

            store.renameConversation(conversation.id, newTitle: "Renamed Chat")

            let updated = store.conversation(for: conversation.id)
            #expect(updated?.title == "Renamed Chat")
        }

        @Test
        func `update conversations merges with remote`() throws {
            let local = try #require(store.createConversation(title: "Local Chat", model: "gpt-4o"))

            let remoteId = UUID()
            let remote = WatchConversation(
                from: Conversation(id: remoteId, title: "Remote Chat", model: "gpt-4")
            )

            store.updateConversations([remote])

            #expect(store.conversation(for: local.id) != nil)
            #expect(store.conversation(for: remoteId) != nil)
        }

        @Test
        func `update conversations preserves local title`() throws {
            let conversation = try #require(store.createConversation(title: "Generated Title", model: "gpt-4o"))

            let syncedConversation = WatchConversation(
                from: Conversation(id: conversation.id, title: "New Chat", model: "gpt-4o")
            )

            store.updateConversations([syncedConversation])

            let updated = store.conversation(for: conversation.id)
            #expect(updated?.title == "Generated Title")
        }

        @Test
        func `update conversations preserves local messages`() throws {
            let conversation = try #require(store.createConversation(model: "gpt-4o"))
            let userMsg = WatchMessage(from: Message(role: .user, content: "Hello"))
            let assistantMsg = WatchMessage(from: Message(role: .assistant, content: "Hi!"))
            store.addMessage(userMsg, to: conversation.id)
            store.addMessage(assistantMsg, to: conversation.id)

            var syncedConversation = WatchConversation(
                from: Conversation(id: conversation.id, title: "New Chat", model: "gpt-4o")
            )
            syncedConversation.messages = [userMsg]

            store.updateConversations([syncedConversation])

            let updated = store.conversation(for: conversation.id)
            #expect(updated?.messages.count == 2)
        }

        @Test
        func `update conversations sorts by recent`() async throws {
            let older = try #require(store.createConversation(title: "Older", model: "gpt-4o"))
            try? await Task.sleep(for: .milliseconds(100))
            let newer = try #require(store.createConversation(title: "Newer", model: "gpt-4o"))

            #expect(store.conversations.first?.id == newer.id)

            var updatedOlder = WatchConversation(
                from: Conversation(id: older.id, title: "Older Updated", model: "gpt-4o")
            )
            updatedOlder.updatedAt = Date()

            store.updateConversations([updatedOlder])

            #expect(store.conversations.first?.id == older.id)
        }
    }

#endif
