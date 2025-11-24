//
//  EncryptedConversationStore.swift
//  ayna
//
//  Created on 11/14/25.
//

import CryptoKit
import Foundation
import os.log

final class EncryptedConversationStore: Sendable {
    static let shared = EncryptedConversationStore()

    private let directoryURL: URL
    private let legacyFileURL: URL
    private let keyIdentifier: String
    private let keychain: KeychainStoring

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
        let keyIdentifier = keyIdentifier
        let keychain = keychain

        return try await Task.detached(priority: .userInitiated) {
            // 1. Check for legacy file and migrate if needed
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                DiagnosticsLogger.log(
                    .encryptedStore, level: .info, message: "Found legacy conversation file, migrating..."
                )
                do {
                    let conversations = try Self.loadLegacyFile(
                        at: legacyFileURL, keyIdentifier: keyIdentifier, keychain: keychain
                    )
                    // Save all to new format
                    for conversation in conversations {
                        try Self.save(
                            conversation, to: directoryURL, keyIdentifier: keyIdentifier, keychain: keychain
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

            return await withTaskGroup(of: Conversation?.self) { group in
                for url in fileURLs where url.pathExtension == "enc" {
                    group.addTask {
                        do {
                            return try Self.load(
                                from: url, keyIdentifier: keyIdentifier, keychain: keychain
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
                for await conversation in group {
                    if let conversation {
                        conversations.append(conversation)
                    }
                }
                return conversations
            }
        }.value
    }

    func save(_ conversation: Conversation) async throws {
        let directoryURL = directoryURL
        let keyIdentifier = keyIdentifier
        let keychain = keychain

        try await Task.detached(priority: .userInitiated) {
            try Self.save(
                conversation, to: directoryURL, keyIdentifier: keyIdentifier, keychain: keychain
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

    private static func getEncryptionKey(keyIdentifier: String, keychain: KeychainStoring) throws
        -> SymmetricKey
    {
        if let existing = try keychain.data(for: keyIdentifier) {
            return SymmetricKey(data: existing)
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try keychain.setData(keyData, for: keyIdentifier)
        return newKey
    }

    private static func loadLegacyFile(at url: URL, keyIdentifier: String, keychain: KeychainStoring)
        throws -> [Conversation]
    {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = try getEncryptionKey(keyIdentifier: keyIdentifier, keychain: keychain)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([Conversation].self, from: plaintext)
    }

    private static func load(from url: URL, keyIdentifier: String, keychain: KeychainStoring) throws
        -> Conversation
    {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = try getEncryptionKey(keyIdentifier: keyIdentifier, keychain: keychain)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Conversation.self, from: plaintext)
    }

    private static func save(
        _ conversation: Conversation, to directory: URL, keyIdentifier: String,
        keychain: KeychainStoring
    ) throws {
        let encoded = try JSONEncoder().encode(conversation)
        let key = try getEncryptionKey(keyIdentifier: keyIdentifier, keychain: keychain)
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        let fileURL = directory.appendingPathComponent("\(conversation.id.uuidString).enc")
        try combined.write(to: fileURL, options: .atomic)
    }
}


