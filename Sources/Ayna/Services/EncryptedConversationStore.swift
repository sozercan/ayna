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
        keychain: KeychainStoring = KeychainStorage.shared
    ) {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let baseDirectory = appSupport.appendingPathComponent("Ayna", isDirectory: true)

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
                            conversation, to: directoryURL, keyData: keyData
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
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
            )
            let encryptedFileURLs = fileURLs.filter { $0.pathExtension == "enc" }

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
                if failedCount > 0 && conversations.isEmpty {
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

    func save(_ conversation: Conversation) async throws {
        let directoryURL = directoryURL
        let keyCache = encryptionKeyCache

        try await Task.detached(priority: .userInitiated) {
            let keyData = try keyCache.keyData()
            try Self.save(
                conversation, to: directoryURL, keyData: keyData
            )
        }.value
    }

    func delete(_ conversationId: UUID) async throws {
        let directoryURL = directoryURL

        try await Task.detached(priority: .userInitiated) {
            let fileURL = directoryURL.appendingPathComponent("\(conversationId.uuidString).enc")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
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

    private nonisolated static func load(from url: URL, keyData: Data) throws -> Conversation
    {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Conversation.self, from: plaintext)
    }

    private nonisolated static func save(
        _ conversation: Conversation,
        to directory: URL,
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
    }

    func fileURL(for conversationId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(conversationId.uuidString).enc")
    }
}
