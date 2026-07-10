@testable import Ayna
import Foundation
import Testing

@Suite("ConversationManager Tests", .tags(.viewModel, .persistence))
struct ConversationManagerTests {
    private var defaults: UserDefaults

    init() {
        guard let suite = UserDefaults(suiteName: "ConversationManagerTests") else {
            fatalError("Failed to create UserDefaults suite for tests")
        }
        defaults = suite
        defaults.removePersistentDomain(forName: "ConversationManagerTests")
        AppPreferences.use(defaults)
        defaults.set(false, forKey: "autoGenerateTitle")
    }

    @MainActor
    private func makeManager(directory: URL, keychain: KeychainStoring? = nil, keyIdentifier: String? = nil) -> ConversationManager {
        let keychainToUse = keychain ?? InMemoryKeychainStorage()
        let keyId = keyIdentifier ?? UUID().uuidString
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychainToUse)
        return ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
    }

    @Test("Create new conversation uses selected model")
    @MainActor
    func createNewConversationUsesSelectedModel() throws {
        AIService.keychain = InMemoryKeychainStorage()
        let directory = try TestHelpers.makeTemporaryDirectory()
        let expectedModel = "unit-test-model"

        AIService.shared.selectedModel = expectedModel
        let manager = makeManager(directory: directory)
        manager.createNewConversation()

        #expect(manager.conversations.count == 1)
        #expect(manager.conversations.first?.model == expectedModel)
    }

    @Test("Add message appends and updates timestamp")
    @MainActor
    func addMessageAppendsAndUpdatesTimestamp() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .user, content: "Ping")
        manager.addMessage(to: conversation, message: message)

        #expect(manager.conversations.first?.messages.count == 1)
        #expect(manager.conversations.first?.messages.first?.content == "Ping")
    }

    @Test("Clear all conversations empties encrypted store")
    @MainActor
    func clearAllConversationsEmptiesEncryptedStore() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let store = TestHelpers.makeTestStore(directory: directory, keychain: keychain)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        manager.conversations = [TestHelpers.sampleConversation()]
        try await store.save(manager.conversations)

        manager.clearAllConversations()

        // Wait for async clear
        try await Task.sleep(for: .milliseconds(100))

        #expect(manager.conversations.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("conversations.enc").path))
    }

    @Test("Search finds matches in title and messages")
    @MainActor
    func searchFindsMatchesInTitleAndMessages() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)

        var first = TestHelpers.sampleConversation(title: "Swift Tips")
        first.messages[0].content = "How to use SwiftUI?"
        var second = TestHelpers.sampleConversation(title: "Random Chat")
        second.messages[0].content = "Discussing movies"
        manager.conversations = [first, second]

        let titleResults = manager.searchConversations(query: "Swift")
        let bodyResults = manager.searchConversations(query: "movies")

        #expect(titleResults.count == 1)
        #expect(titleResults.first?.title == "Swift Tips")
        #expect(bodyResults.count == 1)
        #expect(bodyResults.first?.title == "Random Chat")
    }

    @Test("Save immediately persists manual changes")
    @MainActor
    func saveImmediatelyPersistsManualChanges() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-key-id"
        let manager = makeManager(directory: directory, keychain: keychain, keyIdentifier: keyId)

        // Create conversation directly without triggering debounced save
        let conversation = Conversation(title: "Test Conversation", model: "test-model")
        manager.conversations.insert(conversation, at: 0)

        // Manually update the conversation in the array (simulating what ChatView does with chunks)
        if let index = manager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            manager.conversations[index].messages.append(Message(role: .assistant, content: "Partial content"))
        }

        // Save immediately
        let saveTask = try manager.saveImmediately(#require(manager.conversations.first))

        // Wait for the save task to complete
        _ = await saveTask.value

        // Create a new manager to load from disk using the SAME keychain and keyIdentifier
        let newManager = makeManager(directory: directory, keychain: keychain, keyIdentifier: keyId)
        _ = await newManager.loadingTask?.value

        #expect(newManager.conversations.count == 1)
        #expect(newManager.conversations.first?.messages.isEmpty == true)

        let hydrated = await newManager.ensureConversationLoaded(conversation.id)
        #expect(hydrated?.messages.last?.content == "Partial content")
        #expect(newManager.conversations.first?.messages.last?.content == "Partial content")
    }

    @Test("Initial load uses metadata placeholders until conversation is selected")
    @MainActor
    func initialLoadUsesMetadataPlaceholdersUntilConversationIsSelected() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-metadata-placeholder-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Metadata Only")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.count == 1)
        #expect(manager.conversations.first?.id == conversation.id)
        #expect(manager.conversations.first?.title == "Metadata Only")
        #expect(manager.conversations.first?.messages.isEmpty == true)

        let hydrated = await manager.ensureConversationLoaded(conversation.id)
        #expect(hydrated?.messages.count == conversation.messages.count)
        #expect(manager.conversations.first?.messages.count == conversation.messages.count)
    }

    @Test("Hydrating metadata placeholder before export includes message history")
    @MainActor
    func hydratingMetadataPlaceholderBeforeExportIncludesMessageHistory() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-export-hydration-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Export Hydration")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        let placeholder = try #require(manager.conversations.first)
        #expect(placeholder.messages.isEmpty == true)
        #expect(ConversationExporter.generateMarkdown(for: placeholder).contains("Hello") == false)

        let hydrated = try #require(await manager.ensureConversationLoaded(conversation.id))
        let markdown = ConversationExporter.generateMarkdown(for: hydrated)

        #expect(markdown.contains("Hello"))
        #expect(markdown.contains("Hi there"))
    }

    @Test("Metadata-only Spotlight hit hydrates when current metadata does not match")
    func metadataOnlySpotlightHitHydratesWhenCurrentMetadataDoesNotMatch() {
        let id = UUID()
        let metadataOnlyConversation = Conversation(
            id: id,
            title: "Current Title",
            messages: [],
            metadataPreview: "Current preview"
        )
        let metadataSearchTextById = [id: "Current Title Current preview"]
        let staleSpotlightIds: Set<UUID> = [id]

        #expect(
            ConversationManager.metadataOnlySpotlightHitNeedsHydration(
                metadataOnlyConversation,
                query: "old deleted term",
                metadataSearchTextById: metadataSearchTextById,
                metadataOnlyConversationIds: [id],
                spotlightIds: staleSpotlightIds
            )
        )
        #expect(
            !ConversationManager.metadataOnlySpotlightHitNeedsHydration(
                metadataOnlyConversation,
                query: "current preview",
                metadataSearchTextById: metadataSearchTextById,
                metadataOnlyConversationIds: [id],
                spotlightIds: staleSpotlightIds
            )
        )
    }

    @Test("Selecting metadata placeholder lazy loads full conversation")
    @MainActor
    func selectingMetadataPlaceholderLazyLoadsFullConversation() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-selected-lazy-load-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Lazy Selected")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.first?.messages.isEmpty == true)
        manager.selectedConversationId = conversation.id

        for _ in 0 ..< 20 {
            if manager.conversations.first?.messages.count == conversation.messages.count {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(manager.conversations.first?.messages.count == conversation.messages.count)
    }

    @Test("Lazy hydration repairs unavailable model")
    @MainActor
    func lazyHydrationRepairsUnavailableModel() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-lazy-model-repair-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let defaultModel = AIService.shared.selectedModel.isEmpty
            ? "available-model"
            : AIService.shared.selectedModel
        let unavailableModel = "removed-\(UUID().uuidString)"

        if !AIService.shared.customModels.contains(defaultModel) {
            AIService.shared.customModels.insert(defaultModel, at: 0)
        }
        AIService.shared.selectedModel = defaultModel

        let conversation = TestHelpers.sampleConversation(title: "Repair", model: unavailableModel)
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.first?.model != unavailableModel)
        let hydrated = await manager.ensureConversationLoaded(conversation.id)

        #expect(hydrated?.model != unavailableModel)
        #expect(manager.conversations.first?.model != unavailableModel)
        let persisted = try #require(try await store.loadConversation(id: conversation.id))
        #expect(persisted.model != unavailableModel)
    }

    @Test("Saving metadata placeholder does not persist synthetic preview message")
    @MainActor
    func savingMetadataPlaceholderDoesNotPersistSyntheticPreviewMessage() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-synthetic-preview-save-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Preview Save")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value
        var placeholder = try #require(manager.conversations.first)
        #expect(placeholder.messages.isEmpty == true)
        #expect(placeholder.metadataPreview != nil)

        placeholder.title = "Renamed Preview Save"
        placeholder.updatedAt = Date().addingTimeInterval(60)
        let saveTask = manager.saveImmediately(placeholder)
        _ = await saveTask.value

        let persisted = try #require(try await store.loadConversation(id: conversation.id))
        #expect(persisted.title == "Renamed Preview Save")
        #expect(persisted.messages.count == conversation.messages.count)
    }

    @Test("Later metadata placeholder save replaces pending debounced save")
    @MainActor
    func laterMetadataPlaceholderSaveReplacesPendingDebouncedSave() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-metadata-debounce-latest-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Original Debounced")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(500))
        _ = await manager.loadingTask?.value

        var firstEdit = try #require(manager.conversations.first)
        firstEdit.title = "First Pending Title"
        firstEdit.updatedAt = Date().addingTimeInterval(10)
        manager.save(firstEdit)

        try await Task.sleep(for: .milliseconds(100))

        var secondEdit = firstEdit
        secondEdit.title = "Second Pending Title"
        secondEdit.temperature = 0.42
        secondEdit.updatedAt = Date().addingTimeInterval(20)
        manager.conversations = [secondEdit]
        manager.save(secondEdit)

        try await Task.sleep(for: .milliseconds(700))

        let persisted = try #require(try await store.loadConversation(id: conversation.id))
        #expect(persisted.title == "Second Pending Title")
        #expect(persisted.temperature == 0.42)
        #expect(persisted.messages.count == conversation.messages.count)
    }

    @Test("Lazy hydration preserves newer placeholder metadata edits")
    @MainActor
    func lazyHydrationPreservesNewerPlaceholderMetadataEdits() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-lazy-merge-newer-edits-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        let conversation = TestHelpers.sampleConversation(title: "Original Title")
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        let index = try #require(manager.conversations.firstIndex(where: { $0.id == conversation.id }))
        manager.conversations[index].title = "Edited Before Hydration"
        manager.conversations[index].updatedAt = Date().addingTimeInterval(60)

        let hydrated = await manager.ensureConversationLoaded(conversation.id)

        #expect(hydrated?.title == "Edited Before Hydration")
        #expect(hydrated?.messages.count == conversation.messages.count)
        #expect(manager.conversations[index].title == "Edited Before Hydration")
    }

    @Test("Reload conversations removes stale non-dirty conversations")
    @MainActor
    func reloadConversationsRemovesStaleNonDirtyConversations() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-reconcile-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)

        let kept = TestHelpers.sampleConversation(title: "Kept")
        try await store.save([kept])

        let manager = ConversationManager(store: store, saveDebounceDuration: .milliseconds(0))
        _ = await manager.loadingTask?.value

        #expect(manager.conversations.count == 1)
        #expect(manager.conversations.first?.id == kept.id)

        let stale = TestHelpers.sampleConversation(title: "Stale")
        manager.conversations.append(stale)
        #expect(manager.conversations.count == 2)

        await manager.reloadConversations()

        #expect(manager.conversations.contains(where: { $0.id == kept.id }))
        #expect(!manager.conversations.contains(where: { $0.id == stale.id }))
    }

    @Test("Reload conversations preserves dirty in-memory conversations not yet on disk")
    @MainActor
    func reloadConversationsPreservesDirtyInMemoryConversationsNotYetOnDisk() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-dirty-wins-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value

        let dirty = TestHelpers.sampleConversation(title: "Dirty")
        manager.conversations = [dirty]
        manager.save(dirty)

        // Give the save() Task time to enqueue the pending save.
        try await Task.sleep(for: .milliseconds(50))

        // Confirm it's not on disk yet (debounce is long)
        let diskBefore = try await store.loadConversations()
        #expect(diskBefore.isEmpty)

        await manager.reloadConversations()

        #expect(manager.conversations.contains(where: { $0.id == dirty.id }))

        // Clean up pending saves to avoid test cross-talk.
        manager.clearAllConversations()
    }

    @Test("Reload ignores stale sidecar text for dirty full conversation")
    @MainActor
    func reloadIgnoresStaleSidecarTextForDirtyFullConversation() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let keychain = InMemoryKeychainStorage()
        let keyId = "test-dirty-search-key"
        let store = TestHelpers.makeTestStore(directory: directory, keyIdentifier: keyId, keychain: keychain)
        var conversation = Conversation(title: "Searchable")
        conversation.addMessage(Message(role: .user, content: "old deleted term"))
        try await store.save(conversation)

        let manager = ConversationManager(store: store, saveDebounceDuration: .seconds(10))
        _ = await manager.loadingTask?.value
        let hydrated = try #require(await manager.ensureConversationLoaded(conversation.id))
        let messageId = try #require(hydrated.messages.first?.id)

        #expect(manager.editMessage(in: hydrated, messageId: messageId, newContent: "current replacement"))
        try await Task.sleep(for: .milliseconds(50))

        await manager.reloadConversations()

        #expect(manager.searchConversations(query: "old deleted term").isEmpty)
        #expect(manager.searchConversations(query: "current replacement").map(\.id) == [conversation.id])

        let staleSpotlightResults = await manager.verifiedSearchResults(
            conversations: manager.conversations,
            query: "old deleted term",
            metadataSearchTextById: [:],
            metadataOnlyConversationIds: [],
            spotlightIds: [conversation.id]
        )
        #expect(staleSpotlightResults.isEmpty)

        manager.clearAllConversations()
    }

    // MARK: - Edit Message Tests

    @Test("Edit message updates content and marks as edited")
    @MainActor
    func editMessageUpdatesContentAndMarksAsEdited() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .user, content: "Original content")
        manager.addMessage(to: conversation, message: message)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: message.id,
            newContent: "Edited content"
        )

        #expect(editResult == true)
        #expect(manager.conversations.first?.messages.first?.content == "Edited content")
        #expect(manager.conversations.first?.messages.first?.isEdited == true)
        #expect(manager.conversations.first?.messages.first?.editedAt != nil)
    }

    @Test("Edit message removes subsequent messages")
    @MainActor
    func editMessageRemovesSubsequentMessages() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let userMessage = Message(role: .user, content: "What is 2+2?")
        manager.addMessage(to: conversation, message: userMessage)
        let assistantMessage = Message(role: .assistant, content: "2+2 = 4")
        manager.addMessage(to: conversation, message: assistantMessage)

        #expect(manager.conversations.first?.messages.count == 2)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: userMessage.id,
            newContent: "What is 3+3?"
        )

        #expect(editResult == true)
        #expect(manager.conversations.first?.messages.count == 1)
        #expect(manager.conversations.first?.messages.first?.content == "What is 3+3?")
        #expect(manager.conversations.first?.messages.first?.isEdited == true)
    }

    @Test("Edit message fails for assistant messages")
    @MainActor
    func editMessageFailsForAssistantMessages() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .assistant, content: "Assistant response")
        manager.addMessage(to: conversation, message: message)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: message.id,
            newContent: "Should not work"
        )

        #expect(editResult == false)
        #expect(manager.conversations.first?.messages.first?.content == "Assistant response")
        #expect(manager.conversations.first?.messages.first?.isEdited == false)
    }

    @Test("Edit message with same content does not mark as edited")
    @MainActor
    func editMessageWithSameContentDoesNotMarkAsEdited() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let message = Message(role: .user, content: "Same content")
        manager.addMessage(to: conversation, message: message)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: message.id,
            newContent: "Same content"
        )

        #expect(editResult == true)
        #expect(manager.conversations.first?.messages.first?.content == "Same content")
        #expect(manager.conversations.first?.messages.first?.isEdited == false)
    }

    @Test("Edit message fails for non-existent message")
    @MainActor
    func editMessageFailsForNonExistentMessage() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()

        let manager = makeManager(directory: directory)
        manager.createNewConversation()
        let conversation = try #require(manager.conversations.first)

        let editResult = manager.editMessage(
            in: conversation,
            messageId: UUID(),
            newContent: "Should not work"
        )

        #expect(editResult == false)
    }
}
