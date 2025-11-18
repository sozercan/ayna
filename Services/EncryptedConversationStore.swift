//
//  EncryptedConversationStore.swift
//  ayna
//
//  Created on 11/14/25.
//

import CryptoKit
import Foundation
import os.log

final class EncryptedConversationStore {
    static let shared = EncryptedConversationStore()

    private let fileURL: URL
    private let keyIdentifier: String
    private let keychain: KeychainStoring

    init(
        fileURL: URL? = nil,
        keyIdentifier: String = "conversation_encryption_key",
        keychain: KeychainStoring = KeychainStorage.shared
    ) {
        if let explicitURL = fileURL {
            self.fileURL = explicitURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let directory = appSupport.appendingPathComponent("Ayna", isDirectory: true)

            if !FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            self.fileURL = directory.appendingPathComponent("conversations.enc")
        }

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

    func loadConversations() throws -> [Conversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            log("Encrypted conversation file missing", level: .info)
            return []
        }

        do {
            let encryptedData = try Data(contentsOf: fileURL)
            let box = try AES.GCM.SealedBox(combined: encryptedData)
            let plaintext = try AES.GCM.open(box, using: encryptionKey())
            let conversations = try JSONDecoder().decode([Conversation].self, from: plaintext)
            log("Loaded encrypted conversations", metadata: ["count": "\(conversations.count)"])
            return conversations
        } catch {
            log(
                "Failed to load encrypted conversations",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            throw error
        }
    }

    func save(_ conversations: [Conversation]) throws {
        do {
            let encoded = try JSONEncoder().encode(conversations)
            let sealed = try AES.GCM.seal(encoded, using: encryptionKey())
            guard let combined = sealed.combined else {
                throw KeychainStorageError.unexpectedStatus(errSecParam)
            }
            try combined.write(to: fileURL, options: .atomic)
            log("Saved encrypted conversations", metadata: ["count": "\(conversations.count)"])
        } catch {
            log(
                "Failed to save encrypted conversations",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            throw error
        }
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.removeItem(at: fileURL)
                log("Cleared encrypted conversation file")
            } catch {
                log(
                    "Failed to clear encrypted conversation file",
                    level: .error,
                    metadata: ["error": error.localizedDescription]
                )
                throw error
            }
        }
    }

    private func encryptionKey() throws -> SymmetricKey {
        if let existing = try keychain.data(for: keyIdentifier) {
            return SymmetricKey(data: existing)
        }

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        do {
            try keychain.setData(keyData, for: keyIdentifier)
            log("Generated new encryption key")
        } catch {
            log(
                "Failed to persist encryption key",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            throw error
        }
        return newKey
    }
}
