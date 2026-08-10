@testable import Ayna
import Foundation
import Testing

@Suite("AttachmentStorage Tests", .tags(.persistence, .async), .serialized)
@MainActor
struct AttachmentStorageTests {
    @Test
    func `saving primes the in-process attachment cache`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let data = Data("cached attachment".utf8)

        let path = try storage.save(data: data, extension: "bin")

        #expect(storage.cachedData(path: path) == data)
    }

    @Test
    func `async message and attachment helpers load stored data`() async throws {
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

    @Test
    func `async attachment load uses cached data without touching disk`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let data = Data("cached attachment".utf8)
        let path = try storage.save(data: data, extension: "bin")
        try FileManager.default.removeItem(at: storage.fileURL(for: path))

        #expect(await storage.loadData(path: path) == data)
    }

    @Test
    func `cancelled async attachment load exits before disk I/O`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let path = "uncached.bin"
        try Data(repeating: 0xA5, count: 2 * 1_048_576).write(
            to: directory.appendingPathComponent(path),
            options: .atomic
        )

        let result = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return await storage.loadData(path: path)
        }.value

        #expect(result == nil)
        #expect(storage.cachedData(path: path) == nil)
    }

    @Test
    func `clear all removes files and cached attachment data`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let cache = AttachmentDataCache()
        let storage = AttachmentStorage(directoryURL: directory, dataCache: cache)
        let data = Data("private attachment".utf8)
        let path = try storage.save(data: data, extension: "bin")

        try storage.clearAll()

        #expect(storage.cachedData(path: path) == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.fileURL(for: path).path))
        let replacementPath = try storage.save(data: data, extension: "bin")
        #expect(FileManager.default.fileExists(atPath: storage.fileURL(for: replacementPath).path))
    }

    @Test
    func `snapshot cleanup preserves attachments created afterward`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let oldPath = try storage.save(data: Data("old".utf8), extension: "bin")
        let snapshot = try storage.cleanupSnapshot()
        let newData = Data("new".utf8)
        let newPath = try storage.save(data: newData, extension: "bin")

        try storage.clear(snapshot)

        #expect(!FileManager.default.fileExists(atPath: storage.fileURL(for: oldPath).path))
        #expect(FileManager.default.fileExists(atPath: storage.fileURL(for: newPath).path))
        #expect(storage.load(path: newPath) == newData)
    }

    @Test
    func `snapshot cleanup rejects paths outside the attachment directory`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Attachments", isDirectory: true)
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let outsideFile = parent.appendingPathComponent("outside.bin")
        try Data("keep".utf8).write(to: outsideFile)
        let cachedPath = try storage.save(data: Data("cached".utf8), extension: "bin")

        for invalidPath in ["../outside.bin", ".", ".."] {
            #expect(throws: AttachmentStorageError.self) {
                try storage.clear(AttachmentCleanupSnapshot(fileNames: [invalidPath]))
            }
        }
        #expect(FileManager.default.fileExists(atPath: outsideFile.path))
        #expect(storage.cachedData(path: cachedPath) == Data("cached".utf8))
    }

    @Test
    func `cleanup rejects a symbolic link attachment root without deleting its target`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let targetDirectory = parent.appendingPathComponent("Target", isDirectory: true)
        let linkedDirectory = parent.appendingPathComponent("Attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        let sentinel = targetDirectory.appendingPathComponent("keep.bin")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: targetDirectory
        )
        let storage = AttachmentStorage(
            directoryURL: linkedDirectory,
            dataCache: AttachmentDataCache()
        )

        #expect(throws: AttachmentStorageError.self) {
            try storage.cleanupSnapshot()
        }
        #expect(throws: AttachmentStorageError.self) {
            try storage.clear(AttachmentCleanupSnapshot(fileNames: [sentinel.lastPathComponent]))
        }
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @Test
    func `generation validity includes the active cleanup fence`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let generation = storage.currentGeneration()

        #expect(storage.isCurrentGeneration(generation))
        storage.beginCleanup()
        defer { storage.finishCleanup() }

        #expect(!storage.isCurrentGeneration(generation))
        #expect(!storage.isCurrentGeneration(storage.currentGeneration()))
    }

    @Test
    func `cleanup fence can be acquired before snapshot enumeration`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        _ = try storage.save(data: Data("old".utf8), extension: "bin")

        storage.beginCleanup()
        defer { storage.finishCleanup() }

        #expect(throws: AttachmentStorageError.self) {
            try storage.save(data: Data("blocked".utf8), extension: "bin")
        }
        #expect(try storage.cleanupSnapshot().fileNames.count == 1)
    }

    @Test
    func `privacy cleanup blocks writes and rejects stale generations afterward`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let staleGeneration = storage.currentGeneration()
        _ = try storage.save(data: Data("old".utf8), extension: "bin")
        let snapshot = try storage.beginCleanupSnapshot()
        var cleanupFinished = false
        defer {
            if !cleanupFinished {
                storage.finishCleanup()
            }
        }

        #expect(throws: AttachmentStorageError.self) {
            try storage.save(
                data: Data("blocked".utf8),
                extension: "bin",
                generation: staleGeneration
            )
        }
        try storage.clear(snapshot)
        storage.finishCleanup()
        cleanupFinished = true

        #expect(throws: AttachmentStorageError.self) {
            try storage.save(
                data: Data("stale".utf8),
                extension: "bin",
                generation: staleGeneration
            )
        }
        let currentGeneration = storage.currentGeneration()
        let newPath = try storage.save(
            data: Data("new".utf8),
            extension: "bin",
            generation: currentGeneration
        )
        #expect(FileManager.default.fileExists(atPath: storage.fileURL(for: newPath).path))
    }

    @Test
    func `concurrent cleanup leases keep storage fenced until every owner finishes`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        _ = try storage.save(data: Data("old".utf8), extension: "bin")
        _ = try storage.beginCleanupSnapshot()

        let secondSnapshot = try storage.beginCleanupSnapshot()
        try storage.clear(secondSnapshot)
        storage.finishCleanup()

        #expect(throws: AttachmentStorageError.self) {
            try storage.save(data: Data("still blocked".utf8), extension: "bin")
        }

        storage.finishCleanup()

        let path = try storage.save(data: Data("new".utf8), extension: "bin")
        #expect(FileManager.default.fileExists(atPath: storage.fileURL(for: path).path))
    }

    @Test
    func `cleanup accepts filenames produced from unsafe imported extensions`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let path = try storage.save(
            data: Data("attachment".utf8),
            extension: "png\\variant"
        )
        #expect(!path.contains("\\"))

        let snapshot = try storage.beginCleanupSnapshot()
        try storage.clear(snapshot)
        storage.finishCleanup()

        #expect(!FileManager.default.fileExists(atPath: storage.fileURL(for: path).path))
    }

    @Test
    func `cleanup removes legacy filenames containing backslashes`() throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let storage = AttachmentStorage(
            directoryURL: directory,
            dataCache: AttachmentDataCache()
        )
        let legacyFileName = "legacy.png\\variant"
        try Data("legacy".utf8).write(to: directory.appendingPathComponent(legacyFileName))

        let snapshot = try storage.beginCleanupSnapshot()
        try storage.clear(snapshot)
        storage.finishCleanup()

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(legacyFileName).path
        ))
    }
}
