@testable import Ayna
import Foundation
import Testing

@Suite("Encrypted Conversation Store Deletion Tests", .tags(.persistence, .slow))
struct EncryptedConversationStoreDeletionTests {
    @Test
    func `metadata deletion failure preserves conversation and allows retry`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let conversation = TestHelpers.sampleConversation(title: "Retryable Delete")
        let metadataURL = directory
            .appendingPathComponent("Metadata", isDirectory: true)
            .appendingPathComponent("\(conversation.id.uuidString).metadata.enc")
        let removal = FailOnceMetadataRemoval(targetURL: metadataURL)
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            metadataRemovalOperation: { try removal.removeItem(at: $0) }
        )
        try await store.save(conversation)

        await #expect(throws: FailOnceMetadataRemoval.Failure.self) {
            try await store.delete(conversation.id)
        }

        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))
        #expect(FileManager.default.fileExists(atPath: metadataURL.path))
        #expect(try await store.loadConversation(id: conversation.id) == conversation)

        try await store.delete(conversation.id)

        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: conversation.id).path))
        #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
        #expect(try await store.loadConversation(id: conversation.id) == nil)
    }
}

private final class FailOnceMetadataRemoval: @unchecked Sendable {
    enum Failure: Error {
        case injected
    }

    private let targetURL: URL
    private let lock = NSLock()
    private var shouldFail = true

    init(targetURL: URL) {
        self.targetURL = targetURL
    }

    func removeItem(at url: URL) throws {
        lock.lock()
        let failThisAttempt = shouldFail && url.standardizedFileURL == targetURL.standardizedFileURL
        if failThisAttempt {
            shouldFail = false
        }
        lock.unlock()

        if failThisAttempt {
            throw Failure.injected
        }
        try FileManager.default.removeItem(at: url)
    }
}
