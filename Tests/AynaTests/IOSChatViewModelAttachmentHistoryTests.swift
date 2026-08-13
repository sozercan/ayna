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
    }

#endif
