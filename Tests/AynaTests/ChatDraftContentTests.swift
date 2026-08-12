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
}
