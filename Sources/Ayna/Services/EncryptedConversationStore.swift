//
//  EncryptedConversationStore.swift
//  ayna
//
//  Created on 11/14/25.
//

import CryptoKit
import Foundation
import os.log

/// Errors specific to the encrypted conversation store
enum EncryptedStoreError: LocalizedError {
    /// The encryption key was previously created but is now missing (e.g., after device restore/migration)
    /// This indicates the key was deleted or corrupted, and existing encrypted data cannot be recovered
    case keyLost

    var errorDescription: String? {
        switch self {
        case .keyLost:
            "Encryption key was lost. Previously encrypted conversations cannot be recovered. Please contact support if you need assistance."
        }
    }
}

final class EncryptedConversationStore: Sendable {
    nonisolated static let shared = EncryptedConversationStore()

    private let directoryURL: URL
    private let metadataDirectoryURL: URL
    private let legacyFileURL: URL
    private let keyIdentifier: String
    private let keychain: KeychainStoring
    private let encryptionKeyCache: EncryptionKeyCache

    private final class EncryptionKeyCache: @unchecked Sendable {
        private let keyIdentifier: String
        private let keychain: KeychainStoring
        private let lock = NSLock()
        private var cachedKeyData: Data?

        init(keyIdentifier: String, keychain: KeychainStoring) {
            self.keyIdentifier = keyIdentifier
            self.keychain = keychain
        }

        func keyData() throws -> Data {
            lock.lock()
            defer { lock.unlock() }

            if let cachedKeyData {
                return cachedKeyData
            }

            let flagKey = "\(keyIdentifier)_initialized"

            if let existing = try keychain.data(for: keyIdentifier) {
                cachedKeyData = existing
                return existing
            }

            if (try? keychain.string(for: flagKey)) != nil {
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .error,
                    message: "❌ Encryption key missing but initialization flag exists - possible key loss"
                )
                throw EncryptedStoreError.keyLost
            }

            let newKey = SymmetricKey(size: .bits256)
            let newKeyData = newKey.withUnsafeBytes { Data($0) }
            try keychain.setData(newKeyData, for: keyIdentifier)
            try keychain.setString("1", for: flagKey)
            cachedKeyData = newKeyData
            return newKeyData
        }
    }

    init(
        directoryURL: URL? = nil,
        keyIdentifier: String = "conversation_encryption_key",
        keychain: KeychainStoring = KeychainStorage.standard
    ) {
        let baseDirectory = RuntimeEnvironment.defaultApplicationSupportDirectoryURL

        if !FileManager.default.fileExists(atPath: baseDirectory.path) {
            try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }

        if let explicitDirectory = directoryURL {
            self.directoryURL = explicitDirectory
        } else {
            self.directoryURL = baseDirectory.appendingPathComponent("Conversations", isDirectory: true)
        }

        if !FileManager.default.fileExists(atPath: self.directoryURL.path) {
            try? FileManager.default.createDirectory(
                at: self.directoryURL, withIntermediateDirectories: true
            )
        }

        metadataDirectoryURL = self.directoryURL.appendingPathComponent("Metadata", isDirectory: true)
        if !FileManager.default.fileExists(atPath: metadataDirectoryURL.path) {
            try? FileManager.default.createDirectory(
                at: metadataDirectoryURL, withIntermediateDirectories: true
            )
        }

        legacyFileURL = baseDirectory.appendingPathComponent("conversations.enc")
        self.keyIdentifier = keyIdentifier
        self.keychain = keychain
        encryptionKeyCache = EncryptionKeyCache(keyIdentifier: keyIdentifier, keychain: keychain)
    }

    private func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.encryptedStore, level: level, message: message, metadata: metadata)
    }

    func loadConversations() async throws -> [Conversation] {
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL
        let legacyFileURL = legacyFileURL
        let keyCache = encryptionKeyCache

        return try await Task.detached(priority: .userInitiated) {
            // 1. Check for legacy file and migrate if needed
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                let keyData = try keyCache.keyData()
                DiagnosticsLogger.log(
                    .encryptedStore, level: .info, message: "Found legacy conversation file, migrating..."
                )
                do {
                    let conversations = try Self.loadLegacyFile(
                        at: legacyFileURL, keyData: keyData
                    )
                    // Save all to new format
                    for conversation in conversations {
                        try Self.save(
                            conversation,
                            to: directoryURL,
                            metadataDirectory: metadataDirectoryURL,
                            keyData: keyData
                        )
                    }
                    // Delete legacy file
                    try FileManager.default.removeItem(at: legacyFileURL)
                    DiagnosticsLogger.log(.encryptedStore, level: .info, message: "Migration complete")
                    return conversations
                } catch {
                    DiagnosticsLogger.log(
                        .encryptedStore, level: .error, message: "Migration failed",
                        metadata: ["error": error.localizedDescription]
                    )
                    throw error
                }
            }

            // 2. Load from directory
            let encryptedFileURLs = try Self.conversationFileURLs(in: directoryURL)

            guard !encryptedFileURLs.isEmpty else {
                return []
            }

            let keyData = try keyCache.keyData()

            return await withTaskGroup(of: Conversation?.self) { group in
                for url in encryptedFileURLs {
                    group.addTask {
                        do {
                            return try Self.load(
                                from: url, keyData: keyData
                            )
                        } catch {
                            DiagnosticsLogger.log(
                                .encryptedStore, level: .error, message: "Failed to load conversation",
                                metadata: ["file": url.lastPathComponent, "error": error.localizedDescription]
                            )
                            return nil
                        }
                    }
                }

                var conversations: [Conversation] = []
                var failedCount = 0
                for await conversation in group {
                    if let conversation {
                        conversations.append(conversation)
                    } else {
                        failedCount += 1
                    }
                }
                if failedCount > 0, conversations.isEmpty {
                    DiagnosticsLogger.log(
                        .encryptedStore, level: .error,
                        message: "❌ All conversations failed to decrypt",
                        metadata: ["failedCount": "\(failedCount)"]
                    )
                }
                return conversations
            }
        }.value
    }

    func loadConversationMetadata() async throws -> [ConversationMetadata] {
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL
        let legacyFileURL = legacyFileURL
        let keyCache = encryptionKeyCache

        return try await Task.detached(priority: .userInitiated) {
            // Keep metadata loading complete for legacy users. The first metadata load
            // migrates just like loadConversations(); subsequent loads can read small
            // sidecar records instead of full message histories.
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                let keyData = try keyCache.keyData()
                let conversations = try Self.loadLegacyFile(at: legacyFileURL, keyData: keyData)
                for conversation in conversations {
                    try Self.save(
                        conversation,
                        to: directoryURL,
                        metadataDirectory: metadataDirectoryURL,
                        keyData: keyData
                    )
                }
                try FileManager.default.removeItem(at: legacyFileURL)
                return conversations
                    .map(ConversationMetadata.init(conversation:))
                    .sorted { $0.updatedAt > $1.updatedAt }
            }

            let conversationFileURLsById = try Self.conversationFileURLsById(in: directoryURL)
            guard !conversationFileURLsById.isEmpty else {
                return []
            }

            let keyData = try keyCache.keyData()
            let metadataFileURLsById = try Self.metadataFileURLsById(in: metadataDirectoryURL)
            let validConversationIds = Set(conversationFileURLsById.keys)

            let validMetadataFileURLsById = metadataFileURLsById.filter {
                validConversationIds.contains($0.key)
            }
            let sidecarMetadata = await Self.loadMetadataSidecars(
                metadataFileURLsById: validMetadataFileURLsById,
                keyData: keyData
            )

            let staleMetadataIds = Set<UUID>(validMetadataFileURLsById.compactMap { id, metadataURL in
                guard let conversationURL = conversationFileURLsById[id],
                      let metadata = sidecarMetadata[id],
                      metadata.requiresBackfill
                      || Self.metadataSidecarIsOlderThanConversation(
                          metadataURL: metadataURL,
                          conversationURL: conversationURL
                      )
                else {
                    return nil
                }
                return id
            })

            let currentSidecarMetadata = sidecarMetadata.filter { id, _ in
                !staleMetadataIds.contains(id)
            }
            let missingOrStaleMetadata = conversationFileURLsById.filter { id, _ in
                currentSidecarMetadata[id] == nil
            }
            let backfilledMetadata = await Self.loadFullConversationsAsMetadata(
                conversationFileURLsById: missingOrStaleMetadata,
                metadataDirectory: metadataDirectoryURL,
                keyData: keyData
            )

            let metadataPairs = currentSidecarMetadata.map { ($0.key, $0.value) }
                + backfilledMetadata.map { ($0.key, $0.value) }

            return Dictionary(uniqueKeysWithValues: metadataPairs)
                .values
                .sorted { $0.updatedAt > $1.updatedAt }
        }.value
    }

    func loadConversation(id conversationId: UUID) async throws -> Conversation? {
        let fileURL = fileURL(for: conversationId)
        let keyCache = encryptionKeyCache

        return try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return nil
            }
            let keyData = try keyCache.keyData()
            return try Self.load(from: fileURL, keyData: keyData)
        }.value
    }

    func save(_ conversation: Conversation) async throws {
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL
        let keyCache = encryptionKeyCache

        try await Task.detached(priority: .userInitiated) {
            let keyData = try keyCache.keyData()
            try Self.save(
                conversation,
                to: directoryURL,
                metadataDirectory: metadataDirectoryURL,
                keyData: keyData
            )
        }.value
    }

    func delete(_ conversationId: UUID) async throws {
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL

        try await Task.detached(priority: .userInitiated) {
            let fileURL = directoryURL.appendingPathComponent("\(conversationId.uuidString).enc")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            let metadataURL = Self.metadataFileURL(for: conversationId, in: metadataDirectoryURL)
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try? FileManager.default.removeItem(at: metadataURL)
            }
        }.value
    }

    // Deprecated: Use save(_ conversation:) instead
    func save(_ conversations: [Conversation]) async throws {
        for conversation in conversations {
            try await save(conversation)
        }
    }

    func clear() throws {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        )
        for url in fileURLs {
            try FileManager.default.removeItem(at: url)
        }
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try FileManager.default.removeItem(at: legacyFileURL)
        }
        log("Cleared encrypted conversation store")
    }

    // MARK: - Helpers

    private nonisolated static func loadLegacyFile(at url: URL, keyData: Data)
        throws -> [Conversation]
    {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([Conversation].self, from: plaintext)
    }

    private nonisolated static func load(from url: URL, keyData: Data) throws -> Conversation {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Conversation.self, from: plaintext)
    }

    private nonisolated static func loadMetadata(from url: URL, keyData: Data) throws -> ConversationMetadata {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(ConversationMetadata.self, from: plaintext)
    }

    private nonisolated static func save(
        _ conversation: Conversation,
        to directory: URL,
        metadataDirectory: URL,
        keyData: Data
    ) throws {
        let encoded = try JSONEncoder().encode(conversation)
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        let fileURL = directory.appendingPathComponent("\(conversation.id.uuidString).enc")
        try combined.write(to: fileURL, options: .atomic)

        do {
            try saveMetadata(
                ConversationMetadata(conversation: conversation),
                to: metadataDirectory,
                keyData: keyData
            )
        } catch {
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "Failed to save conversation metadata sidecar",
                metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
            )
        }
    }

    private nonisolated static func saveMetadata(
        _ metadata: ConversationMetadata,
        to metadataDirectory: URL,
        keyData: Data
    ) throws {
        try ensureDirectoryExists(metadataDirectory)
        let encoded = try JSONEncoder().encode(metadata)
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        let fileURL = metadataFileURL(for: metadata.id, in: metadataDirectory)
        try combined.write(to: fileURL, options: .atomic)
    }

    private nonisolated static func loadMetadataSidecars(
        metadataFileURLsById: [UUID: URL],
        keyData: Data
    ) async -> [UUID: ConversationMetadata] {
        await withTaskGroup(of: (UUID, ConversationMetadata?).self) { group in
            for (id, url) in metadataFileURLsById {
                group.addTask {
                    do {
                        return try (id, Self.loadMetadata(from: url, keyData: keyData))
                    } catch {
                        DiagnosticsLogger.log(
                            .encryptedStore,
                            level: .error,
                            message: "Failed to load conversation metadata",
                            metadata: ["file": url.lastPathComponent, "error": error.localizedDescription]
                        )
                        return (id, nil)
                    }
                }
            }

            var metadataById: [UUID: ConversationMetadata] = [:]
            metadataById.reserveCapacity(metadataFileURLsById.count)
            for await (id, metadata) in group {
                if let metadata {
                    metadataById[id] = metadata
                }
            }

            return metadataById
        }
    }

    private nonisolated static func metadataSidecarIsOlderThanConversation(
        metadataURL: URL,
        conversationURL: URL
    ) -> Bool {
        let sameSaveTimestampTolerance: TimeInterval = 1
        do {
            let metadataValues = try metadataURL.resourceValues(forKeys: [.contentModificationDateKey])
            let conversationValues = try conversationURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let metadataDate = metadataValues.contentModificationDate,
                  let conversationDate = conversationValues.contentModificationDate
            else {
                return true
            }
            return conversationDate.timeIntervalSince(metadataDate) > sameSaveTimestampTolerance
        } catch {
            return true
        }
    }

    private nonisolated static func loadFullConversationsAsMetadata(
        conversationFileURLsById: [UUID: URL],
        metadataDirectory: URL,
        keyData: Data
    ) async -> [UUID: ConversationMetadata] {
        await withTaskGroup(of: (UUID, ConversationMetadata?).self) { group in
            for (id, url) in conversationFileURLsById {
                group.addTask {
                    do {
                        let conversation = try Self.load(from: url, keyData: keyData)
                        let metadata = ConversationMetadata(conversation: conversation)
                        try? Self.saveMetadata(metadata, to: metadataDirectory, keyData: keyData)
                        return (id, metadata)
                    } catch {
                        DiagnosticsLogger.log(
                            .encryptedStore,
                            level: .error,
                            message: "Failed to backfill conversation metadata",
                            metadata: ["file": url.lastPathComponent, "error": error.localizedDescription]
                        )
                        return (id, nil)
                    }
                }
            }

            var metadataById: [UUID: ConversationMetadata] = [:]
            for await (id, metadata) in group {
                if let metadata {
                    metadataById[id] = metadata
                }
            }
            return metadataById
        }
    }

    private nonisolated static func conversationFileURLs(in directory: URL) throws -> [URL] {
        try conversationFileURLsById(in: directory).values.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    private nonisolated static func conversationFileURLsById(in directory: URL) throws -> [UUID: URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return [:]
        }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return Dictionary(
            uniqueKeysWithValues: fileURLs.compactMap { url in
                guard url.pathExtension == "enc",
                      url.deletingPathExtension().lastPathComponent.contains(".") == false,
                      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                else {
                    return nil
                }
                return (id, url)
            }
        )
    }

    private nonisolated static func metadataFileURLsById(in metadataDirectory: URL) throws -> [UUID: URL] {
        guard FileManager.default.fileExists(atPath: metadataDirectory.path) else {
            return [:]
        }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil
        )
        return Dictionary(
            uniqueKeysWithValues: fileURLs.compactMap { url in
                guard let id = metadataId(from: url) else {
                    return nil
                }
                return (id, url)
            }
        )
    }

    private nonisolated static func metadataId(from url: URL) -> UUID? {
        let suffix = ".metadata.enc"
        let fileName = url.lastPathComponent
        guard fileName.hasSuffix(suffix) else {
            return nil
        }
        let idString = String(fileName.dropLast(suffix.count))
        return UUID(uuidString: idString)
    }

    private nonisolated static func metadataFileURL(for conversationId: UUID, in metadataDirectory: URL) -> URL {
        metadataDirectory.appendingPathComponent("\(conversationId.uuidString).metadata.enc")
    }

    private nonisolated static func ensureDirectoryExists(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    func fileURL(for conversationId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(conversationId.uuidString).enc")
    }

    func metadataFileURL(for conversationId: UUID) -> URL {
        Self.metadataFileURL(for: conversationId, in: metadataDirectoryURL)
    }
}
