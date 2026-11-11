@testable import Ayna
import Foundation
import Testing

@Suite("Chat Draft Content Tests", .tags(.fast))
struct ChatDraftContentTests {
    @Test
    func `non-image attachments alone are not sendable`() {
        let fileURLs = [
            URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/document.pdf"),
        ]

        #expect(!ChatDraftContent.isSendable(
            text: " \n ",
            fileURLs: fileURLs,
            inMemoryImageCount: 0
        ))
    }

    @Test
    func `dropped files skip duplicates and keep non-image files`() {
        let existing = [URL(fileURLWithPath: "/tmp/photo.png")]
        let dropped = [
            URL(fileURLWithPath: "/tmp/photo.png"),
            URL(fileURLWithPath: "/tmp/./notes.txt"),
            URL(fileURLWithPath: "/tmp/other.jpg"),
            URL(fileURLWithPath: "/tmp/notes.txt"),
        ]

        let selection = ChatDraftContent.filesToAttach(dropped, existing: existing, inMemoryImageCount: 0)

        #expect(selection.accepted.map(\.lastPathComponent) == ["notes.txt", "other.jpg"])
        #expect(selection.skippedImageCount == 0)
    }

    @Test
    func `dropped images beyond the image limit are skipped`() {
        let existing = (0 ..< ChatDraftContent.maximumImageCount - 2).map {
            URL(fileURLWithPath: "/tmp/existing-\($0).png")
        }
        let dropped = [
            URL(fileURLWithPath: "/tmp/a.png"),
            URL(fileURLWithPath: "/tmp/report.pdf"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
            URL(fileURLWithPath: "/tmp/c.webp"),
        ]

        let selection = ChatDraftContent.filesToAttach(dropped, existing: existing, inMemoryImageCount: 1)

        #expect(selection.accepted.map(\.lastPathComponent) == ["a.png", "report.pdf"])
        #expect(selection.skippedImageCount == 2)
    }

    @Test
    func `image attachment alone is sendable`() {
        #expect(ChatDraftContent.isSendable(
            text: "",
            fileURLs: [URL(fileURLWithPath: "/tmp/photo.PNG")],
            inMemoryImageCount: 0
        ))
    }

    @Test
    func `text alone is sendable`() {
        #expect(ChatDraftContent.isSendable(
            text: " Describe this ",
            fileURLs: [],
            inMemoryImageCount: 0
        ))
    }

    @Test
    func `in-memory image alone is sendable`() {
        #expect(ChatDraftContent.isSendable(
            text: "",
            fileURLs: [],
            inMemoryImageCount: 1
        ))
    }

    @Test
    func `remaining image capacity counts draft images across sources`() {
        let fileURLs = [
            URL(fileURLWithPath: "/tmp/photo.png"),
            URL(fileURLWithPath: "/tmp/notes.txt"),
            URL(fileURLWithPath: "/tmp/second.webp"),
        ]

        #expect(ChatDraftContent.remainingImageCapacity(
            fileURLs: fileURLs,
            inMemoryImageCount: 3
        ) == ChatDraftContent.maximumImageCount - 5)
        #expect(ChatDraftContent.remainingImageCapacity(
            fileURLs: fileURLs,
            inMemoryImageCount: ChatDraftContent.maximumImageCount
        ) == 0)
    }

    @Test
    func `built non-image attachments alone are not sendable`() {
        let attachments = [
            Message.FileAttachment(
                fileName: "document.pdf",
                mimeType: "application/pdf",
                data: Data("document".utf8)
            ),
        ]

        #expect(!ChatDraftContent.isSendable(text: "", attachments: attachments))
    }

    @Test
    func `built provider image attachment alone is sendable`() {
        let attachments = [
            Message.FileAttachment(
                fileName: "photo.png",
                mimeType: "image/png",
                data: Data([0x89, 0x50, 0x4E, 0x47])
            ),
        ]

        #expect(ChatDraftContent.isSendable(text: "", attachments: attachments))
    }

    @Test
    func `request history includes a user message only once by identity`() {
        let userMessage = Message(role: .user, content: "Retry me")
        let assistantMessage = Message(role: .assistant, content: "")

        let appended = ChatDraftContent.messagesByIncludingUserMessageIfNeeded(
            userMessage,
            in: [assistantMessage]
        )
        let reused = ChatDraftContent.messagesByIncludingUserMessageIfNeeded(
            userMessage,
            in: [userMessage, assistantMessage]
        )

        #expect(appended.map(\.id) == [assistantMessage.id, userMessage.id])
        #expect(reused.map(\.id) == [userMessage.id, assistantMessage.id])
    }

    @Test
    func `edited history changes the target and excludes later messages without mutation`() throws {
        let userMessage = Message(role: .user, content: "Original")
        let assistantMessage = Message(role: .assistant, content: "Old response")
        var conversation = Conversation(model: "test-model", systemPromptMode: .disabled)
        conversation.messages = [userMessage, assistantMessage]

        let history = try #require(ChatDraftContent.effectiveHistory(
            byEditingUserMessage: userMessage.id,
            newContent: "Replacement",
            in: conversation
        ))

        #expect(history.count == 1)
        #expect(history.first?.id == userMessage.id)
        #expect(history.first?.content == "Replacement")
        #expect(conversation.messages == [userMessage, assistantMessage])
        #expect(ChatDraftContent.effectiveHistory(
            byEditingUserMessage: assistantMessage.id,
            newContent: "Invalid",
            in: conversation
        ) == nil)
    }
}
