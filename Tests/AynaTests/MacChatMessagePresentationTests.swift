#if os(macOS)

    @testable import Ayna
    import Testing

    @Suite("Mac Chat Message Presentation Tests", .tags(.fast))
    struct MacChatMessagePresentationTests {
        @Test
        func `reasoning-only assistant output remains visible and persistent`() {
            let message = Message(
                role: .assistant,
                content: "",
                reasoning: "Partial reasoning"
            )

            #expect(MacChatMessagePresentation.isVisible(
                message,
                lastMessageID: nil,
                isGenerating: false
            ))
            #expect(!MacChatMessagePresentation.isRemovableAssistantPlaceholder(message))
        }

        @Test
        func `empty assistant placeholder remains removable`() {
            let message = Message(role: .assistant, content: "")

            #expect(MacChatMessagePresentation.isRemovableAssistantPlaceholder(message))
            #expect(!MacChatMessagePresentation.isVisible(
                message,
                lastMessageID: nil,
                isGenerating: false
            ))
            #expect(MacChatMessagePresentation.isVisible(
                message,
                lastMessageID: message.id,
                isGenerating: true
            ))
        }
    }

#endif
