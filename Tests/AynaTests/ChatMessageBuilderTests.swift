@testable import Ayna
import Foundation
import Testing

#if os(macOS)
    @Suite("ChatMessageBuilder Tests", .tags(.persistence, .async), .serialized)
    @MainActor
    struct ChatMessageBuilderTests {
        @Test
        func `user message keeps pasted image bytes inline`() async throws {
            let firstImageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
            let secondImageData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
            let firstPastedImage = PastedImage(
                data: firstImageData,
                mimeType: "image/png",
                fileExtension: "png"
            )
            let secondPastedImage = PastedImage(
                data: secondImageData,
                mimeType: "image/png",
                fileExtension: "png"
            )

            let message = await ChatMessageBuilder.createUserMessage(
                text: "",
                appContent: nil,
                fileURLs: [],
                pastedImages: [firstPastedImage, secondPastedImage]
            )
            let attachments = try #require(message.attachments)

            #expect(message.content.isEmpty)
            #expect(attachments.count == 2)
            #expect(Set(attachments.map(\.fileName)).count == 2)
            #expect(attachments.allSatisfy { $0.fileName.hasSuffix(".png") })
            #expect(attachments.allSatisfy { $0.mimeType == "image/png" })
            #expect(attachments.map(\.data) == [firstImageData, secondImageData])
            #expect(attachments.allSatisfy { $0.localPath == nil })
        }

        @Test
        func `pasted image is saved to attachment storage when requested`() async throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: directory,
                dataCache: AttachmentDataCache()
            )
            let imageData = Data([0xFF, 0xD8, 0xFF, 0xE0])
            let pastedImage = PastedImage(
                data: imageData,
                mimeType: "image/jpeg",
                fileExtension: "jpg"
            )

            let attachments = await ChatMessageBuilder.buildAttachments(
                from: [],
                pastedImages: [pastedImage],
                saveToStorage: true,
                attachmentStorage: storage
            )
            let attachment = try #require(attachments.first)
            let localPath = try #require(attachment.localPath)

            #expect(attachments.count == 1)
            #expect(attachment.fileName.hasSuffix(".jpg"))
            #expect(attachment.mimeType == "image/jpeg")
            #expect(attachment.data == nil)
            #expect(localPath.hasSuffix(".jpg"))
            #expect(storage.load(path: localPath) == imageData)
        }

        @Test
        func `fenced attachment storage falls back to inline bytes`() async throws {
            let directory = try TestHelpers.makeTemporaryDirectory()
            let storage = AttachmentStorage(
                directoryURL: directory,
                dataCache: AttachmentDataCache()
            )
            let fileURL = directory.appendingPathComponent("prompt.txt")
            let fileData = Data("keep these bytes".utf8)
            try fileData.write(to: fileURL)
            _ = try storage.beginCleanupSnapshot()
            defer { storage.finishCleanup() }

            let attachments = await ChatMessageBuilder.buildAttachments(
                from: [fileURL],
                saveToStorage: true,
                attachmentStorage: storage
            )
            let attachment = try #require(attachments.first)

            #expect(attachment.localPath == nil)
            #expect(attachment.data == fileData)
        }

        @Test
        func `attachment read started before clear cannot save into the new generation`() async throws {
            let parent = try TestHelpers.makeTemporaryDirectory()
            let storageDirectory = parent.appendingPathComponent("Attachments", isDirectory: true)
            let storage = AttachmentStorage(
                directoryURL: storageDirectory,
                dataCache: AttachmentDataCache()
            )
            let fileURL = parent.appendingPathComponent("prompt.txt")
            let fileData = Data("stale attachment".utf8)
            try fileData.write(to: fileURL)
            let loadGate = AttachmentReadGate(data: fileData)

            let buildTask = Task { @MainActor in
                await ChatMessageBuilder.buildAttachments(
                    from: [fileURL],
                    saveToStorage: true,
                    attachmentStorage: storage,
                    fileDataLoader: { _ in
                        await loadGate.load()
                    }
                )
            }
            await loadGate.waitUntilStarted()
            let snapshot = try storage.beginCleanupSnapshot()
            try storage.clear(snapshot)
            storage.finishCleanup()
            await loadGate.release()
            let attachments = await buildTask.value
            let attachment = try #require(attachments.first)

            #expect(attachment.localPath == nil)
            #expect(attachment.data == fileData)
            #expect(try FileManager.default.contentsOfDirectory(atPath: storageDirectory.path).isEmpty)
        }
    }

    private actor AttachmentReadGate {
        private let data: Data
        private var started = false
        private var released = false
        private var startedContinuations: [CheckedContinuation<Void, Never>] = []
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        init(data: Data) {
            self.data = data
        }

        func load() async -> Data {
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
            return data
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
#endif
