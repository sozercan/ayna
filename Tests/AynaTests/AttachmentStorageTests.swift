@testable import Ayna
import Foundation
import Testing

@Suite("AttachmentStorage Tests", .tags(.persistence, .async), .serialized)
@MainActor
struct AttachmentStorageTests {
    @Test("Saving primes the in-process attachment cache")
    func savePrimesAttachmentCache() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let data = Data("cached attachment".utf8)

        let path = try storage.save(data: data, extension: "bin")

        #expect(storage.cachedData(path: path) == data)
    }

    @Test("Async message and attachment helpers load stored data")
    func asyncHelpersLoadStoredData() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let data = Data("stored attachment".utf8)
        let path = try storage.save(data: data, extension: "png")

        let originalAsyncLoader = Message.attachmentAsyncLoader
        defer { Message.attachmentAsyncLoader = originalAsyncLoader }
        Message.attachmentAsyncLoader = { requestedPath in
            await storage.loadData(path: requestedPath)
        }

        let message = Message(
            role: .assistant,
            content: "",
            mediaType: .image,
            imagePath: path
        )
        let attachment = Message.FileAttachment(
            fileName: "example.png",
            mimeType: "image/png",
            data: nil,
            localPath: path
        )

        #expect(await message.loadEffectiveImageData() == data)
        #expect(await attachment.loadContent() == data)
    }
}
