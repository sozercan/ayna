#if os(iOS)

    @testable import Ayna
    import Foundation
    import Testing

    @Suite("iOS Attachment History Tests", .tags(.viewModel), .serialized)
    @MainActor
    struct IOSChatViewModelAttachmentHistoryTests {
        @Test
        func `apple Intelligence attachment history is rejected before committing a text turn`() {
            let model = "apple-test"
            let priorImageMessage = Message(
                role: .user,
                content: "",
                attachments: [Message.FileAttachment(
                    fileName: "prior.png",
                    mimeType: "image/png",
                    data: Data([0x89, 0x50, 0x4E, 0x47])
                )]
            )
            let conversation = Conversation(
                messages: [priorImageMessage],
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

            let aiService = AIService(urlSession: URLSession(configuration: .ephemeral))
            aiService.customModels = [model]
            aiService.selectedModel = model
            aiService.modelProviders[model] = .appleIntelligence
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )
            viewModel.messageText = "Continue without images"

            viewModel.sendMessage()

            #expect(manager.conversation(byId: conversation.id)?.messages.map(\.id) == [priorImageMessage.id])
            #expect(viewModel.messageText == "Continue without images")
            #expect(viewModel.errorMessage?.contains("does not support attachments") == true)
            #expect(!viewModel.isGenerating)
        }

        @Test
        func `apple Intelligence model-switch retry preserves the existing response`() {
            let sourceModel = "openai-test"
            let appleModel = "apple-test"
            let priorImageMessage = Message(
                role: .user,
                content: "",
                attachments: [Message.FileAttachment(
                    fileName: "prior.png",
                    mimeType: "image/png",
                    data: Data([0x89, 0x50, 0x4E, 0x47])
                )]
            )
            let assistantMessage = Message(
                role: .assistant,
                content: "Existing response",
                model: sourceModel
            )
            let conversation = Conversation(
                messages: [priorImageMessage, assistantMessage],
                model: sourceModel,
                systemPromptMode: .disabled
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = AIService(urlSession: URLSession(configuration: .ephemeral))
            aiService.customModels = [sourceModel, appleModel]
            aiService.selectedModel = sourceModel
            aiService.modelProviders[sourceModel] = .openai
            aiService.modelProviders[appleModel] = .appleIntelligence
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )

            viewModel.switchModelAndRetry(beforeMessage: assistantMessage, newModel: appleModel)

            #expect(manager.conversation(byId: conversation.id)?.messages.map(\.id) == [
                priorImageMessage.id,
                assistantMessage.id,
            ])
            #expect(viewModel.errorMessage?.contains("does not support attachments") == true)
            #expect(!viewModel.isGenerating)
        }

        @Test
        func `image generation model-switch retry preserves an attachment response`() {
            let sourceModel = "openai-test"
            let imageModel = "image-test"
            let userMessage = Message(
                role: .user,
                content: "",
                attachments: [Message.FileAttachment(
                    fileName: "prior.png",
                    mimeType: "image/png",
                    data: Data([0x89, 0x50, 0x4E, 0x47])
                )]
            )
            let assistantMessage = Message(
                role: .assistant,
                content: "Existing response",
                model: sourceModel
            )
            let conversation = Conversation(
                messages: [userMessage, assistantMessage],
                model: sourceModel,
                systemPromptMode: .disabled
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = AIService(urlSession: URLSession(configuration: .ephemeral))
            aiService.customModels = [sourceModel, imageModel]
            aiService.selectedModel = sourceModel
            aiService.modelProviders[sourceModel] = .openai
            aiService.modelEndpointTypes[imageModel] = .imageGeneration
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )

            viewModel.switchModelAndRetry(beforeMessage: assistantMessage, newModel: imageModel)

            #expect(manager.conversation(byId: conversation.id)?.messages.map(\.id) == [
                userMessage.id,
                assistantMessage.id,
            ])
            #expect(viewModel.errorMessage?.contains("do not accept attachments") == true)
            #expect(!viewModel.isGenerating)
        }

        @Test(.timeLimit(.minutes(1)))
        func `anthropic historical image is rejected before committing a text turn`() async throws {
            let model = "claude-test"
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let storedPath = try storage.save(
                data: Data(repeating: 0, count: 12),
                extension: "heic"
            )
            let priorImageMessage = Message(
                role: .user,
                content: "Prior image",
                attachments: [Message.FileAttachment(
                    fileName: "prior.heic",
                    mimeType: "image/heic",
                    localPath: storedPath
                )]
            )
            let priorResponse = Message(
                role: .assistant,
                content: "Prior response",
                model: model
            )
            let conversation = Conversation(
                messages: [priorImageMessage, priorResponse],
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

            let aiService = AIService(urlSession: URLSession(configuration: .ephemeral))
            aiService.customModels = [model]
            aiService.selectedModel = model
            aiService.modelProviders[model] = .anthropic
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            viewModel.messageText = "Continue without a new image"

            viewModel.sendMessage()
            #expect(await waitUntil {
                viewModel.errorMessage?.contains("Unsupported image format") == true
            })

            #expect(manager.conversation(byId: conversation.id)?.messages.map(\.id) == [
                priorImageMessage.id,
                priorResponse.id,
            ])
            #expect(viewModel.messageText == "Continue without a new image")
            #expect(!viewModel.isGenerating)
            viewModel.cancelOwnedOperations()
        }

        @Test(.timeLimit(.minutes(1)))
        func `openAI corrupt historical image is rejected before committing a text turn`() async throws {
            let model = "openai-test"
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let storedPath = try storage.save(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                extension: "png"
            )
            let priorImageMessage = Message(
                role: .user,
                content: "Prior image",
                attachments: [Message.FileAttachment(
                    fileName: "corrupt.png",
                    mimeType: "image/png",
                    localPath: storedPath
                )]
            )
            let priorResponse = Message(
                role: .assistant,
                content: "Prior response",
                model: model
            )
            let conversation = Conversation(
                messages: [priorImageMessage, priorResponse],
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

            let aiService = AIService(urlSession: URLSession(configuration: .ephemeral))
            aiService.customModels = [model]
            aiService.selectedModel = model
            aiService.modelProviders[model] = .openai
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )
            viewModel.messageText = "Continue without a new image"

            viewModel.sendMessage()
            #expect(await waitUntil {
                viewModel.errorMessage?.contains("invalid or corrupted") == true
            })

            #expect(manager.conversation(byId: conversation.id)?.messages.map(\.id) == [
                priorImageMessage.id,
                priorResponse.id,
            ])
            #expect(viewModel.messageText == "Continue without a new image")
            #expect(!viewModel.isGenerating)
            viewModel.cancelOwnedOperations()
        }

        @Test
        func `anthropic image-limit model switch preserves the existing response`() {
            let sourceModel = "openai-test"
            let anthropicModel = "claude-test"
            let imageAttachment = Message.FileAttachment(
                fileName: "image.png",
                mimeType: "image/png",
                data: Data([0x89, 0x50, 0x4E, 0x47])
            )
            let userMessage = Message(
                role: .user,
                content: "Many images",
                attachments: Array(
                    repeating: imageAttachment,
                    count: AnthropicRequestBuilder.maxImagesPerRequest + 1
                )
            )
            let assistantMessage = Message(
                role: .assistant,
                content: "Existing response",
                model: sourceModel
            )
            let conversation = Conversation(
                messages: [userMessage, assistantMessage],
                model: sourceModel,
                systemPromptMode: .disabled
            )
            let manager = ConversationManager(
                store: ScriptedConversationStore(),
                saveDebounceDuration: .zero,
                searchIndexWarmupEnabled: false,
                startsLoadingImmediately: false
            )
            manager.conversations = [conversation]

            let aiService = AIService(urlSession: URLSession(configuration: .ephemeral))
            aiService.customModels = [sourceModel, anthropicModel]
            aiService.selectedModel = sourceModel
            aiService.modelProviders[sourceModel] = .openai
            aiService.modelProviders[anthropicModel] = .anthropic
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService
            )

            viewModel.switchModelAndRetry(beforeMessage: assistantMessage, newModel: anthropicModel)

            #expect(manager.conversation(byId: conversation.id)?.messages.map(\.id) == [
                userMessage.id,
                assistantMessage.id,
            ])
            #expect(viewModel.errorMessage?.contains("at most 20 images") == true)
            #expect(!viewModel.isGenerating)
        }

        @Test(.timeLimit(.minutes(1)))
        func `anthropic legacy retry validates stored image before removing the response`() async throws {
            let model = "claude-test"
            let storageDirectory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let storedPath = try storage.save(
                data: Data([0x89, 0x50, 0x4E, 0x47]),
                extension: "png"
            )
            let userMessage = Message(
                role: .user,
                content: "Corrupt image",
                attachments: [Message.FileAttachment(
                    fileName: "corrupt.png",
                    mimeType: "image/png",
                    localPath: storedPath
                )]
            )
            let assistantMessage = Message(role: .assistant, content: "Existing response")
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

            let aiService = AIService(urlSession: URLSession(configuration: .ephemeral))
            aiService.customModels = [model]
            aiService.selectedModel = model
            aiService.modelProviders[model] = .anthropic
            let viewModel = IOSChatViewModel(
                conversationId: conversation.id,
                conversationManager: manager,
                aiService: aiService,
                attachmentStorage: storage
            )

            viewModel.retryMessage(beforeMessage: assistantMessage)
            #expect(await waitUntil {
                viewModel.errorMessage?.contains("invalid or corrupted") == true
            })

            #expect(manager.conversation(byId: conversation.id)?.messages.map(\.id) == [
                userMessage.id,
                assistantMessage.id,
            ])
            #expect(!viewModel.isGenerating)
            viewModel.cancelOwnedOperations()
        }

        private func waitUntil(
            timeout: Duration = .seconds(2),
            _ condition: @MainActor () -> Bool
        ) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !condition(), clock.now < deadline {
                await Task.yield()
            }
            return condition()
        }
    }

#endif
