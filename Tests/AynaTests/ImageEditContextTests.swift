@testable import Ayna
import Foundation
import Testing

@Suite("ImageEditContext Tests", .tags(.fast))
struct ImageEditContextTests {
    private let pngData = Data([0x89, 0x50, 0x4E, 0x47])
    private let jpegData = Data([0xFF, 0xD8, 0xFF])

    private func previousImage(path: String = "previous.png") -> Message {
        Message(role: .assistant, content: "", mediaType: .image, imagePath: path)
    }

    @Test
    func `attached images on the latest user message take precedence over the previous image`() {
        let user = Message(
            role: .user,
            content: "Remove the watermark",
            attachments: [
                Message.FileAttachment(fileName: "photo.jpg", mimeType: "image/jpeg", data: jpegData),
                Message.FileAttachment(fileName: "notes.txt", mimeType: "text/plain", data: Data("x".utf8)),
                Message.FileAttachment(fileName: "stored.webp", mimeType: "image/webp", localPath: "stored.webp"),
            ]
        )
        let conversation = Conversation(messages: [
            Message(role: .user, content: "Draw a cat"),
            previousImage(),
            user,
            Message(role: .assistant, content: "", mediaType: .image),
        ])

        let context = ImageEditContext.resolve(in: conversation)

        #expect(context?.origin == .attachments)
        #expect(context?.references.map(\.fileName) == ["photo.jpg", "stored.webp"])
        #expect(context?.references.map(\.mimeType) == ["image/jpeg", "image/webp"])
    }

    @Test
    func `without attachments the latest generated image is used and placeholders are skipped`() {
        let conversation = Conversation(messages: [
            Message(role: .user, content: "Draw a cat"),
            previousImage(path: "cat.png"),
            Message(role: .user, content: "Make it orange"),
            Message(role: .assistant, content: "", mediaType: .image),
        ])

        let context = ImageEditContext.resolve(in: conversation)

        #expect(context?.origin == .previousImage)
        #expect(context?.references.map(\.localPath) == ["cat.png"])
        #expect(context?.references.map(\.mimeType) == ["image/png"])
    }

    @Test
    func `an explicit user message overrides the conversation's latest user message`() {
        let pending = Message(
            role: .user,
            content: "Brighten",
            attachments: [Message.FileAttachment(fileName: "a.png", mimeType: "image/png", data: pngData)]
        )
        let conversation = Conversation(messages: [Message(role: .user, content: "Earlier")])

        let context = ImageEditContext.resolve(in: conversation, userMessage: pending)

        #expect(context?.origin == .attachments)
        #expect(context?.references.first?.data == pngData)
    }

    @Test
    func `a text-only conversation has no edit sources`() {
        let conversation = Conversation(messages: [Message(role: .user, content: "Draw a cat")])
        #expect(ImageEditContext.resolve(in: conversation) == nil)
    }

    @Test
    func `loading stored attachments resolves local paths`() async throws {
        let context = ImageEditContext(
            origin: .attachments,
            references: [
                .init(fileName: "a.png", mimeType: "image/png", data: pngData, localPath: nil),
                .init(fileName: "b.jpg", mimeType: "image/jpeg", data: nil, localPath: "b.jpg"),
            ]
        )
        let jpegData = jpegData

        let images = try await context.loadSourceImages { path in
            path == "b.jpg" ? jpegData : nil
        }

        #expect(images == [
            OpenAIImageService.SourceImage(data: pngData, mimeType: "image/png", fileName: "a.png"),
            OpenAIImageService.SourceImage(data: jpegData, mimeType: "image/jpeg", fileName: "b.jpg"),
        ])
    }

    @Test
    func `a missing user attachment fails instead of silently generating from scratch`() async {
        let context = ImageEditContext(
            origin: .attachments,
            references: [.init(fileName: "gone.png", mimeType: "image/png", data: nil, localPath: "gone.png")]
        )

        await #expect(throws: AynaError.self) {
            _ = try await context.loadSourceImages { _ in nil }
        }
    }

    @Test
    func `a missing previous image falls back to generation`() async throws {
        let context = ImageEditContext(
            origin: .previousImage,
            references: [.init(fileName: "image.png", mimeType: "image/png", data: nil, localPath: "gone.png")]
        )

        let images = try await context.loadSourceImages { _ in nil }

        #expect(images.isEmpty)
    }
}
