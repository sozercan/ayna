@testable import Ayna
import Foundation
import Testing

@Suite("Conversation Send Preflight Tests", .tags(.viewModel, .async))
@MainActor
struct ConversationSendPreflightTests {
    @Test
    func `attachment preflight combines policy and data validation`() async {
        let service = AIService(urlSession: URLSession(configuration: .ephemeral))
        let imageModel = "image-test"
        let openAIModel = "openai-test"
        service.modelEndpointTypes[imageModel] = .imageGeneration
        service.modelProviders[openAIModel] = .openai
        let storedImage = Message(
            role: .user,
            content: "Image",
            attachments: [Message.FileAttachment(
                fileName: "stored.png",
                mimeType: "image/png",
                localPath: "stored.png"
            )]
        )

        let policyFailure = await ConversationSendPreflight.attachmentFailure(
            models: [imageModel],
            messages: [storedImage],
            aiService: service,
            loadAttachmentData: { _ in Data() }
        )
        let dataFailure = await ConversationSendPreflight.attachmentFailure(
            models: [openAIModel],
            messages: [storedImage],
            aiService: service,
            loadAttachmentData: { _ in Data([0x89, 0x50, 0x4E, 0x47]) }
        )

        #expect(policyFailure?.message.contains("do not accept attachments") == true)
        #expect(dataFailure?.message.contains("invalid or corrupted") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    // swiftlint:disable:next identifier_name
    func `Send preflight waits for full history before request preparation`() async throws {
        let priorUser = Message(role: .user, content: "Prior question")
        let priorAssistant = Message(role: .assistant, content: "Prior answer")
        let conversation = Conversation(
            messages: [priorUser, priorAssistant],
            model: "model-a",
            systemPromptMode: .disabled
        )
        let gate = ConversationSendLoadGate(conversation: conversation)
        let manager = ConversationManager(
            store: ScriptedConversationStore(),
            saveDebounceDuration: .zero,
            conversationLoader: { conversationId in
                await gate.load(conversationId)
            },
            conversationMetadataLoader: {
                [ConversationMetadata(conversation: conversation)]
            },
            searchIndexWarmupEnabled: false
        )
        await manager.loadingTask?.value
        let completion = ConversationSendCompletionProbe()

        let preflightTask = Task { @MainActor in
            let loaded = await ConversationSendPreflight.loadConversationHistory(
                conversationId: conversation.id,
                manager: manager
            )
            completion.complete()
            return loaded
        }
        await gate.waitUntilStarted()

        #expect(!completion.isComplete)
        #expect(manager.conversations.first?.messages.isEmpty == true)

        await gate.release()
        var hydrated = try #require(await preflightTask.value)
        #expect(completion.isComplete)

        hydrated.addMessage(Message(role: .user, content: "New question"))
        hydrated.addMessage(Message(role: .assistant, content: ""))
        let requestHistory = hydrated.getEffectiveHistory()
        #expect(requestHistory.map(\.role) == [.user, .assistant, .user])
        #expect(requestHistory.map(\.content) == ["Prior question", "Prior answer", "New question"])
    }

    @Test(.timeLimit(.minutes(1)))
    // swiftlint:disable:next identifier_name
    func `Send preflight rejects a metadata placeholder protected by pending persistence`() async {
        let conversation = Conversation(
            messages: [Message(role: .user, content: "Stored history")],
            model: "model-a",
            systemPromptMode: .disabled
        )
        let store = ScriptedConversationStore()
        let saveHandle = await store.enqueue(.save(conversation.id, nil), blocked: true)
        let manager = ConversationManager(
            store: store,
            saveDebounceDuration: .zero,
            conversationLoader: { conversationId in
                conversationId == conversation.id ? conversation : nil
            },
            conversationMetadataLoader: {
                [ConversationMetadata(conversation: conversation)]
            },
            searchIndexWarmupEnabled: false
        )
        await manager.loadingTask?.value

        let pendingSave = manager.persistProposedConversation(conversation)
        await saveHandle.started.wait()

        let loaded = await ConversationSendPreflight.loadConversationHistory(
            conversationId: conversation.id,
            manager: manager
        )

        #expect(loaded == nil)
        #expect(manager.isMetadataOnlyConversation(conversation.id))
        await saveHandle.releaseGate.open()
        _ = await pendingSave.value
    }

    #if os(macOS)
        @Test(.timeLimit(.minutes(1)))
        // swiftlint:disable:next identifier_name
        func `Restored macOS auto-send claim is consumed after a successful retry`() async throws {
            let prompt = "Deep-link prompt"
            let conversation = Conversation(
                title: "Existing conversation",
                model: "model-a",
                systemPromptMode: .disabled
            )
            let store = ScriptedConversationStore()
            let manager = ConversationManager(
                store: store,
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]
            let claim = MacPendingAutoSendClaim(
                conversationID: conversation.id,
                prompt: prompt
            )

            claim.restore(in: manager)
            await manager.flushPendingSaves()
            #expect(manager.conversation(byId: conversation.id)?.pendingAutoSendPrompt == prompt)

            manager.addMessage(
                to: conversation,
                message: Message(role: .user, content: prompt)
            )
            claim.consume(
                committedPrompt: prompt,
                conversationID: conversation.id,
                in: manager
            )
            await manager.flushPendingSaves()

            #expect(manager.conversation(byId: conversation.id)?.pendingAutoSendPrompt == nil)
            let persisted = try #require(await store.persistedConversations().first(where: {
                $0.id == conversation.id
            }))
            #expect(persisted.pendingAutoSendPrompt == nil)
            #expect(persisted.messages.contains { message in
                message.role == .user && message.content == prompt
            })
        }
    #endif
}

@MainActor
private final class ConversationSendCompletionProbe {
    private(set) var isComplete = false

    func complete() {
        isComplete = true
    }
}

private actor ConversationSendLoadGate {
    private let conversation: Conversation
    private var started = false
    private var released = false
    private var startedContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(conversation: Conversation) {
        self.conversation = conversation
    }

    func load(_ conversationId: UUID) async -> Conversation? {
        guard conversationId == conversation.id else { return nil }
        started = true
        for continuation in startedContinuations {
            continuation.resume()
        }
        startedContinuations.removeAll()

        if !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        return conversation
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
