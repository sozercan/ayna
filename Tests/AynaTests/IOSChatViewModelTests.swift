#if os(iOS)

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("iOS Chat View Model Tests", .tags(.viewModel), .serialized)
    @MainActor
    struct IOSChatViewModelTests {
        @Test(.timeLimit(.minutes(1)))
        func `single-model send waits for lazy history and includes it in the request`() async throws {
            let priorUser = Message(role: .user, content: "Prior question")
            let priorAssistant = Message(role: .assistant, content: "Prior answer")
            let conversation = Conversation(
                messages: [priorUser, priorAssistant],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "New question"

            viewModel.sendMessage()
            await gate.waitUntilStarted()

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.isEmpty == true)
            #expect(viewModel.messageText == "New question")
            viewModel.messageText = "Later draft"

            await gate.release()
            #expect(await waitUntil { aiService.singleModelRequests.count == 1 })

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.role) == [.user, .assistant, .user])
            #expect(request.map(\.content) == ["Prior question", "Prior answer", "New question"])
            #expect(!request.contains { $0.role == .assistant && $0.content.isEmpty })
            #expect(viewModel.messageText == "Later draft")
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `accepted send rotates the paste import session before lazy history finishes`() async {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Send while paste import is pending"
            let initialSessionID = viewModel.pasteImportSessionID

            viewModel.sendMessage()

            #expect(viewModel.pasteImportSessionID != initialSessionID)
            await gate.waitUntilStarted()
            #expect(aiService.singleModelRequests.isEmpty)

            await gate.release()
            #expect(await waitUntil { aiService.singleModelRequests.count == 1 })
            viewModel.cancelOwnedOperations()
        }

        @Test
        func `send is ignored while a pasted image import is pending`() {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            let pastedImage = PastedImage(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png",
                fileExtension: "png"
            )
            viewModel.messageText = "Wait for the paste"
            viewModel.pastedImages = [pastedImage]
            viewModel.isImportingPastedImages = true
            let initialSessionID = viewModel.pasteImportSessionID

            viewModel.sendMessage()

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversation(byId: conversation.id)?.messages.isEmpty == true)
            #expect(viewModel.messageText == "Wait for the paste")
            #expect(viewModel.pastedImages == [pastedImage])
            #expect(viewModel.pasteImportSessionID == initialSessionID)
            #expect(!viewModel.isGenerating)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `anthropic image limit is rejected before committing the message`() async throws {
            let model = "claude-test"
            let conversation = Conversation(model: model, systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [model])
            aiService.modelProviders[model] = .anthropic
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            viewModel.pastedImages = (0 ... ChatDraftContent.maximumImageCount).map { index in
                PastedImage(
                    data: Data([0x89, 0x50, 0x4E, 0x47, UInt8(index), 0, 0, 0, 0, 0, 0, 0]),
                    mimeType: "image/png",
                    fileExtension: "png"
                )
            }

            viewModel.sendMessage()
            #expect(await waitUntil { viewModel.errorMessage?.contains("at most 20 images") == true })

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversation(byId: conversation.id)?.messages.isEmpty == true)
            #expect(viewModel.pastedImages.count == ChatDraftContent.maximumImageCount + 1)
            #expect(!viewModel.isGenerating)
            #expect(try FileManager.default.contentsOfDirectory(atPath: storageDirectory.path).isEmpty)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `oversized anthropic file image is rejected before committing the message`() async throws {
            let model = "claude-test"
            let conversation = Conversation(model: model, systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [model])
            aiService.modelProviders[model] = .anthropic
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            let directory = try TestHelpers.makeTemporaryDirectory()
            let fileURL = directory.appendingPathComponent("large.jpg")
            var imageData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])
            imageData.append(Data(
                repeating: 0,
                count: AnthropicRequestBuilder.maxImageSizeBytes
            ))
            try imageData.write(to: fileURL)
            viewModel.attachedFiles = [fileURL]

            viewModel.sendMessage()
            #expect(await waitUntil { viewModel.errorMessage?.contains("Image too large") == true })

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversation(byId: conversation.id)?.messages.isEmpty == true)
            #expect(viewModel.attachedFiles == [fileURL])
            #expect(!viewModel.isGenerating)
            #expect(try FileManager.default.contentsOfDirectory(atPath: storageDirectory.path).isEmpty)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `multi-model send waits for lazy history and includes it in the request`() async throws {
            let priorUser = Message(role: .user, content: "Prior question")
            let priorAssistant = Message(role: .assistant, content: "Prior answer")
            let models = ["model-a", "model-b"]
            let conversation = Conversation(
                messages: [priorUser, priorAssistant],
                model: models[0],
                systemPromptMode: .disabled,
                multiModelEnabled: true,
                activeModels: models
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: models)
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.selectedModels = Set(models)
            viewModel.messageText = "New comparison"

            viewModel.sendMessage()
            await gate.waitUntilStarted()

            #expect(aiService.multiModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.isEmpty == true)
            #expect(viewModel.messageText == "New comparison")
            viewModel.messageText = "Later comparison draft"
            viewModel.selectedModels = [models[0]]

            await gate.release()
            #expect(await waitUntil { aiService.multiModelRequests.count == 1 })

            let request = try #require(aiService.multiModelRequests.first)
            #expect(request.map(\.role) == [.user, .assistant, .user])
            #expect(request.map(\.content) == ["Prior question", "Prior answer", "New comparison"])
            #expect(!request.contains { $0.role == .assistant && $0.content.isEmpty })
            #expect(viewModel.messageText == "Later comparison draft")
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `attachment-only multi-model send preserves the captured paste`() async throws {
            let models = ["model-a", "model-b"]
            let conversation = Conversation(
                messages: [Message(role: .user, content: "Prior question")],
                model: models[0],
                systemPromptMode: .disabled,
                multiModelEnabled: true,
                activeModels: models
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: models)
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            let capturedPaste = PastedImage(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                mimeType: "image/png",
                fileExtension: "png"
            )
            let laterPaste = PastedImage(
                data: Data([0xFF, 0xD8, 0xFF, 0xE0]),
                mimeType: "image/jpeg",
                fileExtension: "jpg"
            )
            viewModel.selectedModels = Set(models)
            viewModel.pastedImages = [capturedPaste]

            viewModel.sendMessage()
            await gate.waitUntilStarted()

            #expect(aiService.multiModelRequests.isEmpty)
            viewModel.pastedImages.append(laterPaste)

            await gate.release()
            #expect(await waitUntil { aiService.multiModelRequests.count == 1 })

            let request = try #require(aiService.multiModelRequests.first)
            let sentMessage = try #require(request.last(where: { $0.role == .user }))
            let attachment = try #require(sentMessage.attachments?.first)
            #expect(sentMessage.content.isEmpty)
            #expect(sentMessage.attachments?.count == 1)
            #expect(attachment.fileName == capturedPaste.fileName)
            #expect(attachment.mimeType == capturedPaste.mimeType)
            #expect(attachment.data == nil)
            let localPath = try #require(attachment.localPath)
            #expect(storage.load(path: localPath) == capturedPaste.data)
            #expect(viewModel.pastedImages == [laterPaste])
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `multi-model reasoning routes by model and rejects stale operation callbacks`() async throws {
            let models = ["model-a", "model-b"]
            let conversation = Conversation(
                model: models[0],
                systemPromptMode: .disabled,
                multiModelEnabled: true,
                activeModels: models
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = MultiModelReasoningCapturingAIService()
            configure(aiService, models: models)
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.selectedModels = Set(models)
            viewModel.messageText = "First comparison"

            viewModel.sendMessage()
            #expect(aiService.reasoningCallbackCount == 1)
            let firstGroup = try #require(manager.conversation(byId: conversation.id)?.responseGroups.last)
            let firstA = try #require(firstGroup.responses.first(where: { $0.modelName == models[0] }))
            let firstB = try #require(firstGroup.responses.first(where: { $0.modelName == models[1] }))

            aiService.emitReasoning(requestIndex: 0, model: models[0], reasoning: "first-a")
            aiService.emitReasoning(requestIndex: 0, model: models[1], reasoning: "first-b")
            #expect(await waitUntil {
                let messages = manager.conversation(byId: conversation.id)?.messages ?? []
                return messages.first(where: { $0.id == firstA.id })?.reasoning == "first-a"
                    && messages.first(where: { $0.id == firstB.id })?.reasoning == "first-b"
            })

            viewModel.cancelGeneration()
            viewModel.messageText = "Replacement comparison"
            viewModel.sendMessage()
            #expect(aiService.reasoningCallbackCount == 2)
            let secondGroup = try #require(manager.conversation(byId: conversation.id)?.responseGroups.last)
            #expect(secondGroup.id != firstGroup.id)
            let secondA = try #require(secondGroup.responses.first(where: { $0.modelName == models[0] }))
            let secondB = try #require(secondGroup.responses.first(where: { $0.modelName == models[1] }))

            aiService.emitReasoning(requestIndex: 0, model: models[0], reasoning: "-stale")
            aiService.emitReasoning(requestIndex: 1, model: models[0], reasoning: "second-a")
            #expect(await waitUntil {
                manager.conversation(byId: conversation.id)?.messages.first(where: { $0.id == secondA.id })?.reasoning
                    == "second-a"
            })

            let messages = try #require(manager.conversation(byId: conversation.id)?.messages)
            #expect(messages.first(where: { $0.id == firstA.id })?.reasoning == "first-a")
            #expect(messages.first(where: { $0.id == firstB.id })?.reasoning == "first-b")
            #expect(messages.first(where: { $0.id == secondB.id })?.reasoning == nil)
            viewModel.cancelOwnedOperations()
        }

        @Test
        func `hydrated conversation send remains synchronous`() throws {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Send now"

            viewModel.sendMessage()

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.content) == ["Send now"])
            viewModel.cancelOwnedOperations()
        }

        @Test
        func `reset for new chat clears pasted images and rotates the paste import session`() {
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: ["model-a"])
            let viewModel = IOSChatViewModel(
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.pastedImages = [
                PastedImage(
                    data: Data([0x89, 0x50, 0x4E, 0x47]),
                    mimeType: "image/png",
                    fileExtension: "png"
                )
            ]
            let initialSessionID = viewModel.pasteImportSessionID

            viewModel.resetForNewChat()

            #expect(viewModel.pastedImages.isEmpty)
            #expect(viewModel.pasteImportSessionID != initialSessionID)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `failed lazy history load keeps the draft and attachments without sending`() async {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let gate = IOSConversationLoadGate(result: nil)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            let attachment = URL(fileURLWithPath: "/tmp/unsent-attachment.txt")
            viewModel.messageText = "Keep this draft"
            viewModel.attachedFiles = [attachment]

            viewModel.sendMessage()
            await gate.waitUntilStarted()
            await gate.release()
            #expect(await waitUntil { !viewModel.isGenerating })

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.isEmpty == true)
            #expect(viewModel.messageText == "Keep this draft")
            #expect(viewModel.attachedFiles == [attachment])
            #expect(viewModel.errorMessage != nil)
        }

        @Test(.timeLimit(.minutes(1)))
        func `failed send retry restores pasted images`() async throws {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = ControllableErrorAIService()
            configure(aiService, models: [conversation.model])
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            let pastedImage = PastedImage(
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A]),
                mimeType: "image/png",
                fileExtension: "png"
            )
            viewModel.messageText = "Retry this image"
            viewModel.pastedImages = [pastedImage]

            viewModel.sendMessage()
            #expect(await waitUntil { aiService.requests.count == 1 })
            #expect(viewModel.pastedImages.isEmpty)
            let committedUserMessage = try #require(
                manager.conversation(byId: conversation.id)?.messages.first(where: { $0.role == .user })
            )

            aiService.failLatestRequest()
            #expect(await waitUntil {
                !viewModel.isGenerating && viewModel.failedMessage == "Retry this image"
            })

            viewModel.retryFailedMessage()

            #expect(await waitUntil { aiService.requests.count == 2 })
            let retriedUserMessage = try #require(
                aiService.requests.last?.last(where: { $0.role == .user })
            )
            let retriedAttachment = try #require(retriedUserMessage.attachments?.first)
            let persistedUserMessages = try #require(
                manager.conversation(byId: conversation.id)?.messages.filter { $0.role == .user }
            )
            let requestedUserMessages = try #require(
                aiService.requests.last?.filter { $0.role == .user }
            )
            #expect(retriedAttachment.fileName == pastedImage.fileName)
            #expect(retriedAttachment.mimeType == pastedImage.mimeType)
            #expect(retriedAttachment.data == nil)
            let localPath = try #require(retriedAttachment.localPath)
            #expect(storage.load(path: localPath) == pastedImage.data)
            #expect(persistedUserMessages.map(\.id) == [committedUserMessage.id])
            #expect(requestedUserMessages.map(\.id) == [committedUserMessage.id])
            #expect(viewModel.pastedImages.isEmpty)
            #expect(viewModel.failedMessage == nil)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `failed send retry preserves a newer composer draft`() async throws {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = ControllableErrorAIService()
            configure(aiService, models: [conversation.model])
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            let failedPaste = PastedImage(
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x01]),
                mimeType: "image/png",
                fileExtension: "png"
            )
            let laterPaste = PastedImage(
                data: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x02]),
                mimeType: "image/jpeg",
                fileExtension: "jpg"
            )
            viewModel.messageText = "Retry the failed image"
            viewModel.pastedImages = [failedPaste]

            viewModel.sendMessage()
            #expect(await waitUntil { aiService.requests.count == 1 })
            viewModel.messageText = "Keep this newer draft"
            viewModel.pastedImages = [laterPaste]

            aiService.failLatestRequest()
            #expect(await waitUntil {
                !viewModel.isGenerating && viewModel.failedMessage == "Retry the failed image"
            })
            #expect(viewModel.messageText == "Keep this newer draft")
            #expect(viewModel.pastedImages == [laterPaste])

            viewModel.retryFailedMessage()

            #expect(await waitUntil { aiService.requests.count == 2 })
            let retriedUserMessage = try #require(
                aiService.requests.last?.last(where: { $0.role == .user })
            )
            let retriedAttachment = try #require(retriedUserMessage.attachments?.first)
            #expect(retriedUserMessage.content == "Retry the failed image")
            #expect(retriedUserMessage.attachments?.count == 1)
            #expect(retriedAttachment.fileName == failedPaste.fileName)
            #expect(retriedAttachment.mimeType == failedPaste.mimeType)
            #expect(retriedAttachment.data == nil)
            let localPath = try #require(retriedAttachment.localPath)
            #expect(storage.load(path: localPath) == failedPaste.data)
            #expect(viewModel.messageText == "Keep this newer draft")
            #expect(viewModel.pastedImages == [laterPaste])
            #expect(viewModel.failedMessage == nil)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `all-failed multi-model send retains its pasted image for retry`() async throws {
            let models = ["model-a", "model-b"]
            let conversation = Conversation(
                model: models[0],
                systemPromptMode: .disabled,
                multiModelEnabled: true,
                activeModels: models
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = ControllableMultiModelErrorAIService()
            configure(aiService, models: models)
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            let pastedImage = PastedImage(
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x03]),
                mimeType: "image/png",
                fileExtension: "png"
            )
            viewModel.selectedModels = Set(models)
            viewModel.messageText = "Compare this image"
            viewModel.pastedImages = [pastedImage]

            viewModel.sendMessage()
            #expect(await waitUntil { aiService.requests.count == 1 })
            #expect(viewModel.pastedImages.isEmpty)

            aiService.failAllModelsInLatestRequest()
            #expect(await waitUntil {
                !viewModel.isGenerating && viewModel.failedMessage == "Compare this image"
            })
            #expect(viewModel.errorMessage == "All models failed")

            viewModel.retryFailedMessage()

            #expect(await waitUntil { aiService.requests.count == 2 })
            let retriedUserMessage = try #require(
                aiService.requests.last?.last(where: { $0.role == .user })
            )
            let retriedAttachment = try #require(retriedUserMessage.attachments?.first)
            #expect(retriedUserMessage.content == "Compare this image")
            #expect(retriedUserMessage.attachments?.count == 1)
            #expect(retriedAttachment.fileName == pastedImage.fileName)
            #expect(retriedAttachment.mimeType == pastedImage.mimeType)
            #expect(retriedAttachment.data == nil)
            let localPath = try #require(retriedAttachment.localPath)
            #expect(storage.load(path: localPath) == pastedImage.data)
            #expect(viewModel.failedMessage == nil)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `failed auto-send hydration restores the durable prompt`() async throws {
            let conversation = Conversation(model: "model-a", systemPromptMode: .disabled)
            let gate = IOSConversationLoadGate(result: nil)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            let index = try #require(manager.conversations.firstIndex(where: {
                $0.id == conversation.id
            }))
            manager.conversations[index].pendingAutoSendPrompt = "Deep-link prompt"

            viewModel.configure(with: manager, conversationId: conversation.id)
            await gate.waitUntilStarted()
            await gate.release()
            #expect(await waitUntil { viewModel.errorMessage != nil })

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(viewModel.messageText == "Deep-link prompt")
            #expect(manager.conversation(byId: conversation.id)?.pendingAutoSendPrompt == "Deep-link prompt")
        }

        @Test(.timeLimit(.minutes(1)))
        func `newer auto-send prompt replaces a claim waiting for hydration`() async throws {
            let metadataConversation = Conversation(
                messages: [Message(role: .user, content: "Prior question")],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let storedConversation = metadataConversation
            let gate = IOSConversationLoadGate(result: storedConversation)
            let manager = makeMetadataManager(conversation: metadataConversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [metadataConversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: metadataConversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            let index = try #require(manager.conversations.firstIndex(where: {
                $0.id == metadataConversation.id
            }))
            manager.conversations[index].pendingAutoSendPrompt = "First prompt"

            viewModel.configure(with: manager, conversationId: metadataConversation.id)
            await gate.waitUntilStarted()

            manager.conversations[index].pendingAutoSendPrompt = "Second prompt"
            viewModel.configure(with: manager, conversationId: metadataConversation.id)

            await gate.release()
            #expect(await waitUntil { aiService.singleModelRequests.count == 1 })

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.content) == ["Prior question", "Second prompt"])
            #expect(manager.conversation(byId: metadataConversation.id)?.pendingAutoSendPrompt == nil)
            #expect(!manager.conversations[index].messages.contains { $0.content == "First prompt" })
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `newer auto-send prompt does not cancel a manual send waiting for hydration`() async throws {
            let conversation = Conversation(
                messages: [Message(role: .user, content: "Prior question")],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Manual prompt"

            viewModel.sendMessage()
            await gate.waitUntilStarted()

            let index = try #require(manager.conversations.firstIndex(where: { $0.id == conversation.id }))
            manager.conversations[index].pendingAutoSendPrompt = "Later deep-link prompt"
            viewModel.configure(with: manager, conversationId: conversation.id)

            await gate.release()
            #expect(await waitUntil { aiService.singleModelRequests.count == 1 })

            let request = try #require(aiService.singleModelRequests.first)
            #expect(request.map(\.content) == ["Prior question", "Manual prompt"])
            #expect(manager.conversation(byId: conversation.id)?.pendingAutoSendPrompt == "Later deep-link prompt")
            #expect(!manager.conversations[index].messages.contains { $0.content == "Later deep-link prompt" })
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `cancelling lazy history preparation keeps the draft without sending`() async {
            let conversation = Conversation(
                messages: [Message(role: .user, content: "Prior question")],
                model: "model-a",
                systemPromptMode: .disabled
            )
            let gate = IOSConversationLoadGate(result: conversation)
            let manager = makeMetadataManager(conversation: conversation, gate: gate)
            await manager.loadingTask?.value

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [conversation.model])
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Do not send"
            let completion = IOSSendPreparationCompletionProbe()
            viewModel.sendPreparationDidFinish = {
                completion.finish()
            }

            viewModel.sendMessage()
            await gate.waitUntilStarted()
            viewModel.cancelGeneration()
            await gate.release()
            await completion.wait()

            #expect(aiService.singleModelRequests.isEmpty)
            #expect(manager.conversations.first?.messages.contains { message in
                message.role == .user && message.content == "Do not send"
            } == false)
            #expect(viewModel.messageText == "Do not send")
            #expect(!viewModel.isGenerating)
            viewModel.sendPreparationDidFinish = nil
        }

        @Test
        func `retry sends the selected response model and provider`() async throws {
            AIService.keychain = InMemoryKeychainStorage()
            let conversationModel = "conversation-default"
            let retryModel = "selected-response"
            let userMessage = Message(role: .user, content: "Compare these models")
            let assistantMessage = Message(
                role: .assistant,
                content: "Selected response",
                model: retryModel
            )
            let conversation = Conversation(
                messages: [userMessage, assistantMessage],
                model: conversationModel,
                systemPromptMode: .disabled
            )
            let store = ScriptedConversationStore()
            let manager = ConversationManager(store: store, saveDebounceDuration: .zero)
            await manager.loadingTask?.value
            manager.conversations = [conversation]

            let aiService = RetryCapturingAIService()
            aiService.customModels = [conversationModel, retryModel]
            aiService.selectedModel = conversationModel
            aiService.modelProviders[conversationModel] = .openai
            aiService.modelProviders[retryModel] = .anthropic
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )

            viewModel.retryMessage(beforeMessage: assistantMessage)

            let request = try #require(aiService.capturedRequests.first)
            #expect(request.model == retryModel)
            #expect(request.provider == .anthropic)
            #expect(manager.conversation(byId: conversation.id)?.messages.last?.model == retryModel)
            viewModel.cancelOwnedOperations()
        }

        private func makeMetadataManager(
            conversation: Conversation,
            gate: IOSConversationLoadGate
        ) -> ConversationManager {
            ConversationManager(
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
        }

    }

    @Suite("iOS Chat View Model Regression Tests", .tags(.viewModel), .serialized)
    @MainActor
    struct IOSChatViewModelRegressionTests {
        @Test
        func `attachment-incompatible edit preserves the existing transcript`() {
            let model = "apple-test"
            let userMessage = Message(
                role: .user,
                content: "Original question",
                attachments: [Message.FileAttachment(
                    fileName: "image.png",
                    mimeType: "image/png",
                    data: Data([0x89, 0x50, 0x4E, 0x47])
                )]
            )
            let assistantMessage = Message(role: .assistant, content: "Existing answer")
            let conversation = Conversation(
                messages: [userMessage, assistantMessage],
                model: model,
                systemPromptMode: .disabled
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = SendHistoryCapturingAIService()
            configure(aiService, models: [model])
            aiService.modelProviders[model] = .appleIntelligence
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )

            viewModel.editMessageAndResend(
                userMessage,
                newContent: "Replacement question"
            )

            #expect(manager.conversation(byId: conversation.id)?.messages == [
                userMessage,
                assistantMessage,
            ])
            #expect(viewModel.errorMessage?.contains("does not support attachments") == true)
            #expect(aiService.singleModelRequests.isEmpty)
            #expect(!viewModel.isGenerating)
        }

        @Test(.timeLimit(.minutes(1)))
        func `failed single-model new chat stays on its retry screen`() async throws {
            let model = "model-a"
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            let aiService = ControllableErrorAIService()
            configure(aiService, models: [model])
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let viewModel = IOSChatViewModel(
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: AttachmentStorage(
                    directoryURL: storageDirectory,
                    dataCache: AttachmentDataCache()
                )
            )
            var createdConversationID: UUID?
            viewModel.onConversationCreated = { createdConversationID = $0 }
            viewModel.selectedModel = model
            viewModel.selectedModels = [model]
            viewModel.messageText = "Retry this new chat"
            viewModel.pastedImages = [PastedImage(
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x04]),
                mimeType: "image/png",
                fileExtension: "png"
            )]

            viewModel.sendMessage()
            #expect(await waitUntil { aiService.requests.count == 1 })
            aiService.failLatestRequest()
            #expect(await waitUntil {
                !viewModel.isGenerating && viewModel.failedMessage == "Retry this new chat"
            })

            #expect(createdConversationID == nil)
            #expect(manager.conversations.count == 1)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `all-failed multi-model new chat stays on its retry screen`() async throws {
            let models = ["model-a", "model-b"]
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            let aiService = ControllableMultiModelErrorAIService()
            configure(aiService, models: models)
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let viewModel = IOSChatViewModel(
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: AttachmentStorage(
                    directoryURL: storageDirectory,
                    dataCache: AttachmentDataCache()
                )
            )
            var createdConversationID: UUID?
            viewModel.onConversationCreated = { createdConversationID = $0 }
            viewModel.selectedModel = models[0]
            viewModel.selectedModels = Set(models)
            viewModel.messageText = "Compare this new chat"
            viewModel.pastedImages = [PastedImage(
                data: Data([0x89, 0x50, 0x4E, 0x47, 0x05]),
                mimeType: "image/png",
                fileExtension: "png"
            )]

            viewModel.sendMessage()
            #expect(await waitUntil { aiService.requests.count == 1 })
            aiService.failAllModelsInLatestRequest()
            #expect(await waitUntil {
                !viewModel.isGenerating && viewModel.failedMessage == "Compare this new chat"
            })

            #expect(createdConversationID == nil)
            #expect(viewModel.errorMessage == "All models failed")
            #expect(manager.conversations.count == 1)
            viewModel.cancelOwnedOperations()
        }

    }

    @MainActor
    private func configure(_ service: AIService, models: [String]) {
        service.customModels = models
        service.selectedModel = models[0]
        for model in models {
            service.modelProviders[model] = .openai
            service.modelAPIKeys[model] = "sk-unit-test"
        }
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private actor IOSConversationLoadGate {
        private let result: Conversation?
        private var started = false
        private var released = false
        private var startedContinuations: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        init(result: Conversation?) {
            self.result = result
        }

        func load(_ conversationId: UUID) async -> Conversation? {
            guard conversationId == result?.id || result == nil else { return nil }
            started = true
            for continuation in startedContinuations {
                continuation.resume()
            }
            startedContinuations.removeAll()

            if !released {
                await withCheckedContinuation { continuation in
                    releaseContinuations.append(continuation)
                }
            }
            return result
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { continuation in
                startedContinuations.append(continuation)
            }
        }

        func release() {
            released = true
            for continuation in releaseContinuations {
                continuation.resume()
            }
            releaseContinuations.removeAll()
        }
    }

    @MainActor
    private final class IOSSendPreparationCompletionProbe {
        private var isFinished = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !isFinished else { return }
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func finish() {
            isFinished = true
            continuation?.resume()
            continuation = nil
        }
    }

    private struct CapturedRetryRequest {
        let model: String
        let provider: AIProvider
    }

    private enum ControllableSendError: Error {
        case failed
    }

    @MainActor
    private final class ControllableErrorAIService: AIService {
        private(set) var requests: [[Message]] = []
        private var errorCallbacks: [@Sendable (Error) -> Void] = []

        init() {
            super.init(responseSimulator: { _, _ in })
        }

        override func sendMessage(
            messages: [Message],
            model: String?,
            temperature: Double?,
            stream: Bool,
            tools: [[String: Any]]?,
            conversationId: UUID?,
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            requestFlightID: RequestFlightID?
        ) -> AITextRequest {
            requests.append(messages)
            errorCallbacks.append(onError)
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                requestFlightID: requestFlightID
            )
        }

        func failLatestRequest() {
            errorCallbacks.last?(ControllableSendError.failed)
        }
    }

    @MainActor
    private final class ControllableMultiModelErrorAIService: AIService {
        private(set) var requests: [[Message]] = []
        private var requestModels: [[String]] = []
        private var errorCallbacks: [@Sendable (String, Error) -> Void] = []
        private var allCompleteCallbacks: [@Sendable () -> Void] = []

        init() {
            super.init(responseSimulator: { _, _ in })
        }

        override func sendToMultipleModels(
            messages: [Message],
            models: [String],
            temperature: Double?,
            onChunk: @escaping @Sendable (String, String) -> Void,
            onModelComplete: @escaping @Sendable (String) -> Void,
            onAllComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (String, Error) -> Void,
            onPendingToolCall: (@Sendable (String, String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String, String) -> Void)?
        ) -> AITextBatchRequest {
            requests.append(messages)
            requestModels.append(models)
            errorCallbacks.append(onError)
            allCompleteCallbacks.append(onAllComplete)
            return super.sendToMultipleModels(
                messages: messages,
                models: [],
                temperature: temperature,
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, _ in },
                onPendingToolCall: nil,
                onReasoning: nil
            )
        }

        func failAllModelsInLatestRequest() {
            guard let models = requestModels.last,
                  let onError = errorCallbacks.last,
                  let onAllComplete = allCompleteCallbacks.last
            else {
                return
            }
            for model in models {
                onError(model, ControllableSendError.failed)
            }
            onAllComplete()
        }
    }

    @MainActor
    private final class RetryCapturingAIService: AIService {
        private(set) var capturedRequests: [CapturedRetryRequest] = []

        init() {
            super.init(responseSimulator: { _, _ in })
        }

        override func sendMessage(
            messages: [Message],
            model: String?,
            temperature: Double?,
            stream: Bool,
            tools: [[String: Any]]?,
            conversationId: UUID?,
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            requestFlightID: RequestFlightID?
        ) -> AITextRequest {
            let requestModel = model ?? selectedModel
            capturedRequests.append(
                CapturedRetryRequest(
                    model: requestModel,
                    provider: modelProviders[requestModel] ?? provider
                )
            )
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                requestFlightID: requestFlightID
            )
        }
    }

    @MainActor
    private final class SendHistoryCapturingAIService: AIService {
        private(set) var singleModelRequests: [[Message]] = []
        private(set) var multiModelRequests: [[Message]] = []

        init() {
            super.init(responseSimulator: { _, _ in })
        }

        override func sendMessage(
            messages: [Message],
            model: String?,
            temperature: Double?,
            stream: Bool,
            tools: [[String: Any]]?,
            conversationId: UUID?,
            requestLane: AITextRequestLane,
            isMultiModelRequest: Bool,
            onChunk: @escaping @Sendable (String) -> Void,
            onComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (Error) -> Void,
            onToolCall: (@Sendable (String, String, [String: Any]) async -> String)?,
            onToolCallRequested: (@Sendable (String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String) -> Void)?,
            requestFlightID: RequestFlightID?
        ) -> AITextRequest {
            if !isMultiModelRequest {
                singleModelRequests.append(messages)
            }
            return super.sendMessage(
                messages: messages,
                model: model,
                temperature: temperature,
                stream: stream,
                tools: tools,
                conversationId: conversationId,
                requestLane: requestLane,
                isMultiModelRequest: isMultiModelRequest,
                onChunk: onChunk,
                onComplete: onComplete,
                onError: onError,
                onToolCall: onToolCall,
                onToolCallRequested: onToolCallRequested,
                onReasoning: onReasoning,
                requestFlightID: requestFlightID
            )
        }

        override func sendToMultipleModels(
            messages: [Message],
            models: [String],
            temperature: Double?,
            onChunk: @escaping @Sendable (String, String) -> Void,
            onModelComplete: @escaping @Sendable (String) -> Void,
            onAllComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (String, Error) -> Void,
            onPendingToolCall: (@Sendable (String, String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String, String) -> Void)?
        ) -> AITextBatchRequest {
            multiModelRequests.append(messages)
            return super.sendToMultipleModels(
                messages: messages,
                models: models,
                temperature: temperature,
                onChunk: onChunk,
                onModelComplete: onModelComplete,
                onAllComplete: onAllComplete,
                onError: onError,
                onPendingToolCall: onPendingToolCall,
                onReasoning: onReasoning
            )
        }
    }

    @MainActor
    private final class MultiModelReasoningCapturingAIService: AIService {
        private typealias ReasoningCallback = @Sendable (String, String) -> Void

        private var reasoningCallbacks: [ReasoningCallback?] = []

        var reasoningCallbackCount: Int {
            reasoningCallbacks.count
        }

        init() {
            super.init(responseSimulator: { _, _ in })
        }

        override func sendToMultipleModels(
            messages: [Message],
            models: [String],
            temperature: Double?,
            onChunk: @escaping @Sendable (String, String) -> Void,
            onModelComplete: @escaping @Sendable (String) -> Void,
            onAllComplete: @escaping @Sendable () -> Void,
            onError: @escaping @Sendable (String, Error) -> Void,
            onPendingToolCall: (@Sendable (String, String, String, [String: Any]) -> Void)?,
            onReasoning: (@Sendable (String, String) -> Void)?
        ) -> AITextBatchRequest {
            reasoningCallbacks.append(onReasoning)
            return super.sendToMultipleModels(
                messages: messages,
                models: [],
                temperature: temperature,
                onChunk: { _, _ in },
                onModelComplete: { _ in },
                onAllComplete: {},
                onError: { _, _ in },
                onPendingToolCall: nil,
                onReasoning: nil
            )
        }

        func emitReasoning(requestIndex: Int, model: String, reasoning: String) {
            guard reasoningCallbacks.indices.contains(requestIndex) else { return }
            reasoningCallbacks[requestIndex]?(model, reasoning)
        }
    }

#endif
