@testable import Ayna
import Foundation
import Testing

@Suite("EncryptedConversationStore Clear Transaction Tests", .tags(.persistence, .slow), .serialized)
struct EncryptedStoreClearTransactionTests {
    @Test
    func `store startup purges abandoned clear backups`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let legacyFile = parent.appendingPathComponent("conversations.enc")
        let transactionId = UUID().uuidString
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        let conversationBackup = parent.appendingPathComponent(
            ".AynaConversationClearBackup-\(storeId)-\(transactionId)",
            isDirectory: true
        )
        let legacyBackup = parent.appendingPathComponent(
            ".AynaLegacyClearBackup-\(storeId)-\(transactionId)"
        )
        let commitMarker = parent.appendingPathComponent(
            ".AynaConversationClearCommitted-\(storeId)-\(transactionId)"
        )
        try FileManager.default.createDirectory(
            at: conversationBackup,
            withIntermediateDirectories: true
        )
        try Data("encrypted conversation residue".utf8).write(
            to: conversationBackup.appendingPathComponent("conversation.enc")
        )
        try Data("encrypted legacy residue".utf8).write(to: legacyBackup)
        try Data().write(to: commitMarker)

        _ = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFile,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )

        #expect(!FileManager.default.fileExists(atPath: conversationBackup.path))
        #expect(!FileManager.default.fileExists(atPath: legacyBackup.path))
        #expect(!FileManager.default.fileExists(atPath: commitMarker.path))
    }

    @Test
    func `store startup recovers uncommitted clear rollback backups`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        let transactionId = UUID().uuidString
        let rollbackBackup = parent.appendingPathComponent(
            ".AynaConversationClearBackup-\(storeId)-\(transactionId)",
            isDirectory: true
        )
        let privacyMarker = parent.appendingPathComponent(
            ".AynaConversationPrivacyCleanupPending-\(storeId)-\(transactionId)"
        )
        try FileManager.default.createDirectory(
            at: rollbackBackup,
            withIntermediateDirectories: true
        )
        try Data("only rollback copy".utf8).write(
            to: rollbackBackup.appendingPathComponent("conversation.enc")
        )
        try Data().write(to: privacyMarker)

        _ = TestHelpers.makeTestStore(directory: directory)

        #expect(!FileManager.default.fileExists(atPath: rollbackBackup.path))
        #expect(!FileManager.default.fileExists(atPath: privacyMarker.path))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("conversation.enc").path
        ))
    }

    @Test
    func `store startup recovers standalone legacy rollback backup`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let legacyFile = parent.appendingPathComponent("conversations.enc")
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        let legacyBackup = parent.appendingPathComponent(
            ".AynaLegacyClearBackup-\(storeId)-\(UUID().uuidString)"
        )
        try Data("standalone legacy rollback".utf8).write(to: legacyBackup)

        _ = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFile,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )

        #expect(!FileManager.default.fileExists(atPath: legacyBackup.path))
        #expect(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    @Test
    func `store startup surfaces unresolved clear recovery on reads`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("live partial state".utf8).write(
            to: directory.appendingPathComponent("partial.enc")
        )
        let rollbackBackup = parent.appendingPathComponent(
            ".AynaConversationClearBackup-\(storeId)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rollbackBackup,
            withIntermediateDirectories: true
        )
        try Data("recoverable backup".utf8).write(
            to: rollbackBackup.appendingPathComponent("conversation.enc")
        )
        let store = TestHelpers.makeTestStore(directory: directory)

        do {
            _ = try await store.loadConversationMetadata()
            Issue.record("Expected recovery-required read failure")
        } catch let error as EncryptedStoreError {
            guard case .clearRecoveryRequired = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
    }

    @Test
    func `store startup scan failure blocks reads and writes`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        let rollbackBackup = parent.appendingPathComponent(
            ".AynaConversationClearBackup-\(storeId)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rollbackBackup,
            withIntermediateDirectories: true
        )
        try Data("recoverable backup".utf8).write(
            to: rollbackBackup.appendingPathComponent("conversation.enc")
        )
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            clearArtifactDirectoryContentsOperation: { _ in
                throw CocoaError(.fileReadNoPermission)
            }
        )

        do {
            _ = try await store.loadConversations()
            Issue.record("Expected recovery-required read failure")
        } catch let error as EncryptedStoreError {
            guard case let .clearRecoveryRequired(paths) = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
            #expect(paths.contains(parent.path))
        }

        do {
            try await store.save(TestHelpers.sampleConversation(title: "Blocked After Scan Failure"))
            Issue.record("Expected recovery-required write failure")
        } catch let error as EncryptedStoreError {
            guard case .clearRecoveryRequired = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: rollbackBackup.path))
    }

    @Test
    func `privacy marker scan failure remains pending and blocks loading`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let legacyFile = parent.appendingPathComponent("conversations.enc")
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        let transactionId = UUID().uuidString
        let commitMarker = parent.appendingPathComponent(
            ".AynaConversationClearCommitted-\(storeId)-\(transactionId)"
        )
        let privacyMarker = parent.appendingPathComponent(
            ".AynaConversationPrivacyCleanupPending-\(storeId)-\(transactionId)"
        )
        try Data().write(to: commitMarker)
        try Data().write(to: privacyMarker)
        let listingProbe = FailingPrivacyMarkerListingProbe()
        let store = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFile,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            clearArtifactDirectoryContentsOperation: { directoryURL in
                try listingProbe.contents(of: directoryURL)
            }
        )

        #expect(store.hasPendingPrivacyCleanup())
        do {
            _ = try await store.loadConversations()
            Issue.record("Expected privacy scan failure to block loading")
        } catch let error as EncryptedStoreError {
            guard case .clearRecoveryRequired = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
        #expect(FileManager.default.fileExists(atPath: privacyMarker.path))
        #expect(FileManager.default.fileExists(atPath: commitMarker.path))
    }

    @Test
    func `clear cleanup failure does not restore deleted conversations`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            backupRemovalOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let removed = TestHelpers.sampleConversation(title: "Removed")
        try await store.save(removed)

        do {
            try store.clear()
            Issue.record("Expected committed clear cleanup failure")
        } catch let error as EncryptedStoreError {
            guard case .clearBackupCleanupFailed = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }

        let retained = TestHelpers.sampleConversation(title: "Retained")
        try await store.save(retained)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: removed.id).path))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: retained.id).path))
        do {
            _ = try await store.loadConversations()
            Issue.record("Expected pending cleanup read failure")
        } catch let error as EncryptedStoreError {
            guard case .clearBackupCleanupFailed = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }

        do {
            try store.clear()
            Issue.record("Expected pending-cleanup clear failure")
        } catch let error as EncryptedStoreError {
            guard case .clearCleanupPending = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
    }

    @Test
    func `privacy acknowledgement cannot reclassify a committed backup as rollback data`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let keyIdentifier = UUID().uuidString
        let keychain = InMemoryKeychainStorage()
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain,
            backupRemovalOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )
        let removed = TestHelpers.sampleConversation(title: "Must Stay Deleted")
        try await store.save(removed)

        do {
            try store.clear()
            Issue.record("Expected committed backup cleanup failure")
        } catch let error as EncryptedStoreError {
            guard case .clearBackupCleanupFailed = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
        try store.clearPendingPrivacyCleanup()

        let restartedStore = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: keyIdentifier,
            keychain: keychain
        )

        #expect(try await restartedStore.loadConversation(id: removed.id) == nil)
        #expect(try await restartedStore.loadConversations().isEmpty)
    }

    @Test
    func `startup keeps committed cleanup failures visible`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let transactionId = UUID().uuidString
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        let backup = parent.appendingPathComponent(
            ".AynaConversationClearBackup-\(storeId)-\(transactionId)",
            isDirectory: true
        )
        let marker = parent.appendingPathComponent(
            ".AynaConversationClearCommitted-\(storeId)-\(transactionId)"
        )
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("committed encrypted residue".utf8).write(
            to: backup.appendingPathComponent("conversation.enc")
        )
        try Data().write(to: marker)
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            backupRemovalOperation: { _ in
                throw CocoaError(.fileWriteUnknown)
            }
        )

        do {
            _ = try await store.loadConversationMetadata()
            Issue.record("Expected committed cleanup read failure")
        } catch let error as EncryptedStoreError {
            guard case .clearBackupCleanupFailed = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
    }

    @Test
    func `committed clear leaves privacy cleanup pending until acknowledged`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Privacy Marker"))

        try store.clear()

        #expect(store.hasPendingPrivacyCleanup())
        try store.clearPendingPrivacyCleanup()
        #expect(!store.hasPendingPrivacyCleanup())
    }

    @Test
    func `clear commits attachment cleanup scope with the privacy marker`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Attachment Scope"))
        let attachmentSnapshot = AttachmentCleanupSnapshot(fileNames: ["old-image.png"])

        try store.clear(attachmentCleanupSnapshot: attachmentSnapshot)

        let markerSnapshot = store.pendingPrivacyCleanupMarkerSnapshot()
        switch store.attachmentCleanupPlan(for: markerSnapshot) {
        case let .fileNames(fileNames):
            #expect(fileNames == attachmentSnapshot.fileNames)
        case .completed, .unknown:
            Issue.record("Expected a persisted attachment cleanup scope")
        }
    }

    @Test
    func `committed clear marker survives restart until privacy cleanup is acknowledged`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let storeId = EncryptedConversationStore.clearArtifactIdentifier(for: directory)
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Privacy Commit Marker"))

        try store.clear()

        let artifacts = try FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil
        )
        let privacyMarker = try #require(artifacts.first {
            $0.lastPathComponent.hasPrefix(".AynaConversationPrivacyCleanupPending-\(storeId)-")
        })
        let transactionId = String(
            privacyMarker.lastPathComponent.dropFirst(
                ".AynaConversationPrivacyCleanupPending-\(storeId)-".count
            )
        )
        let commitMarker = parent.appendingPathComponent(
            ".AynaConversationClearCommitted-\(storeId)-\(transactionId)"
        )
        #expect(FileManager.default.fileExists(atPath: commitMarker.path))

        let restartedStore = TestHelpers.makeTestStore(directory: directory)

        #expect(restartedStore.hasPendingPrivacyCleanup())
        #expect(FileManager.default.fileExists(atPath: commitMarker.path))
        try restartedStore.clearPendingPrivacyCleanup()
        #expect(!FileManager.default.fileExists(atPath: privacyMarker.path))
        #expect(!FileManager.default.fileExists(atPath: commitMarker.path))
    }

    @Test
    func `empty store clear remains committed across restart until privacy cleanup is acknowledged`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let store = TestHelpers.makeTestStore(directory: directory)
        try FileManager.default.removeItem(at: directory)

        try store.clear()

        let restartedStore = TestHelpers.makeTestStore(directory: directory)
        #expect(restartedStore.hasPendingPrivacyCleanup())
        try restartedStore.clearPendingPrivacyCleanup()
        #expect(!restartedStore.hasPendingPrivacyCleanup())
    }

    @Test
    func `clear rejects a symbolic link conversation root without deleting its target`() throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let targetDirectory = parent.appendingPathComponent("RelocatedStore", isDirectory: true)
        let linkedDirectory = parent.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: targetDirectory
        )
        let sentinel = targetDirectory.appendingPathComponent("encrypted-conversation.bin")
        try Data("encrypted data".utf8).write(to: sentinel)
        let store = EncryptedConversationStore(
            directoryURL: linkedDirectory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage()
        )

        do {
            try store.clear()
            Issue.record("Expected symbolic-link clear rejection")
        } catch let error as EncryptedStoreError {
            guard case let .unsupportedClearSymbolicLink(path) = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
            #expect(path == linkedDirectory.path)
        }

        #expect(FileManager.default.fileExists(atPath: linkedDirectory.path))
        #expect(try Data(contentsOf: sentinel) == Data("encrypted data".utf8))
    }

    @Test
    func `clear move failure preserves the live conversation store`() async throws {
        let directory = try TestHelpers.makeTemporaryDirectory()
        let store = EncryptedConversationStore(
            directoryURL: directory,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            moveOperation: { source, destination in
                if source == directory {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
        let conversation = TestHelpers.sampleConversation(title: "Must Survive Failed Clear")
        try await store.save(conversation)

        do {
            try store.clear()
            Issue.record("Expected clear move failure")
        } catch {
            // Expected: the source store never moved, so it must remain untouched.
        }

        #expect(try await store.loadConversation(id: conversation.id)?.title == conversation.title)
    }

    @Test
    func `clear keeps the active staging directory available`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let store = TestHelpers.makeTestStore(directory: directory)
        try await store.save(TestHelpers.sampleConversation(title: "Before Clear"))
        let stagingDirectory = try #require(
            FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            ).first { $0.lastPathComponent.hasPrefix(".AynaConversationStaging-") }
        )

        try store.clear()

        #expect(FileManager.default.fileExists(atPath: stagingDirectory.path))
    }

    @Test
    func `failed clear rollback blocks writes until startup recovery`() async throws {
        let parent = try TestHelpers.makeTemporaryDirectory()
        let directory = parent.appendingPathComponent("Store", isDirectory: true)
        let legacyFile = parent.appendingPathComponent("conversations.enc")
        let store = EncryptedConversationStore(
            directoryURL: directory,
            legacyFileURL: legacyFile,
            keyIdentifier: UUID().uuidString,
            keychain: InMemoryKeychainStorage(),
            moveOperation: { source, destination in
                if source == legacyFile
                    || source.lastPathComponent.hasPrefix(".AynaConversationClearBackup-")
                {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.moveItem(at: source, to: destination)
            }
        )
        try await store.save(TestHelpers.sampleConversation(title: "Before Failed Rollback"))
        try Data("legacy trigger".utf8).write(to: legacyFile)

        do {
            try store.clear()
            Issue.record("Expected clear rollback failure")
        } catch let error as EncryptedStoreError {
            guard case .clearRollbackFailed = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }

        do {
            try await store.save(TestHelpers.sampleConversation(title: "Blocked Write"))
            Issue.record("Expected recovery-required save failure")
        } catch let error as EncryptedStoreError {
            guard case .clearRecoveryRequired = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }

        do {
            try store.clear()
            Issue.record("Expected recovery-required clear failure")
        } catch let error as EncryptedStoreError {
            guard case .clearRecoveryRequired = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }

        do {
            try await store.delete(UUID())
            Issue.record("Expected recovery-required delete failure")
        } catch let error as EncryptedStoreError {
            guard case .clearRecoveryRequired = error else {
                Issue.record("Unexpected encrypted store error: \(error)")
                return
            }
        }
    }
}

private final class FailingPrivacyMarkerListingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    func contents(of directoryURL: URL) throws -> [URL] {
        let invocation = lock.withLock { () -> Int in
            invocationCount += 1
            return invocationCount
        }
        if invocation >= 3 {
            throw CocoaError(.fileReadNoPermission)
        }
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )
    }
}
