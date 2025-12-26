//
//  EncryptedMemoryStore.swift
//  ayna
//
//  Created on 12/25/25.
//

import CryptoKit
import Foundation
import os.log

/// Errors specific to the encrypted memory store.
enum EncryptedMemoryStoreError: LocalizedError {
    case keyLost
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .keyLost:
            "Encryption key was lost. User memory cannot be recovered."
        case .encodingFailed:
            "Failed to encode memory data."
        case .decodingFailed:
            "Failed to decode memory data."
        }
    }
}

/// Encrypted storage for user memory facts.
/// Uses the same encryption pattern as EncryptedConversationStore.
final class EncryptedMemoryStore: Sendable {
    nonisolated static let shared = EncryptedMemoryStore()

    private let fileURL: URL
    private let summaryFileURL: URL
    private let keyIdentifier: String
    private let keychain: KeychainStoring

    init(
        directoryURL: URL? = nil,
        keyIdentifier: String = "memory_encryption_key",
        keychain: KeychainStoring = KeychainStorage.shared
    ) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let baseDirectory = appSupport.appendingPathComponent("Ayna", isDirectory: true)

        if !FileManager.default.fileExists(atPath: baseDirectory.path) {
            try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        }

        let memoryDirectory: URL = if let explicitDirectory = directoryURL {
            explicitDirectory
        } else {
            baseDirectory.appendingPathComponent("UserMemory", isDirectory: true)
        }

        if !FileManager.default.fileExists(atPath: memoryDirectory.path) {
            try? FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        }

        fileURL = memoryDirectory.appendingPathComponent("memory.enc")
        summaryFileURL = memoryDirectory.appendingPathComponent("summaries.enc")
        self.keyIdentifier = keyIdentifier
        self.keychain = keychain
    }

    // MARK: - User Memory Operations

    /// Loads the user memory store from encrypted storage.
    func loadMemory() async throws -> UserMemoryStore {
        try await Task.detached(priority: .userInitiated) { [fileURL, keyIdentifier, keychain] in
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return UserMemoryStore()
            }

            let encryptedData = try Data(contentsOf: fileURL)
            let key = try Self.getEncryptionKey(keyIdentifier: keyIdentifier, keychain: keychain)
            let box = try AES.GCM.SealedBox(combined: encryptedData)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(UserMemoryStore.self, from: plaintext)
        }.value
    }

    /// Saves the user memory store to encrypted storage.
    func saveMemory(_ store: UserMemoryStore) async throws {
        let fileURL = fileURL
        let keyIdentifier = keyIdentifier
        let keychain = keychain

        try await Task.detached(priority: .userInitiated) {
            let encoded = try JSONEncoder().encode(store)
            let key = try Self.getEncryptionKey(keyIdentifier: keyIdentifier, keychain: keychain)
            let sealed = try AES.GCM.seal(encoded, using: key)

            guard let combined = sealed.combined else {
                throw EncryptedMemoryStoreError.encodingFailed
            }

            try combined.write(to: fileURL, options: .atomic)

            DiagnosticsLogger.log(
                .encryptedStore,
                level: .info,
                message: "✅ Saved user memory",
                metadata: ["factCount": "\(store.facts.count)"]
            )
        }.value
    }

    /// Clears all user memory.
    func clearMemory() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
        DiagnosticsLogger.log(
            .encryptedStore,
            level: .info,
            message: "🧹 Cleared user memory"
        )
    }

    // MARK: - Conversation Summary Operations

    /// Loads the conversation summaries digest from encrypted storage.
    func loadSummaries() async throws -> RecentConversationsDigest {
        try await Task.detached(priority: .userInitiated) { [summaryFileURL, keyIdentifier, keychain] in
            guard FileManager.default.fileExists(atPath: summaryFileURL.path) else {
                return RecentConversationsDigest()
            }

            let encryptedData = try Data(contentsOf: summaryFileURL)
            let key = try Self.getEncryptionKey(keyIdentifier: keyIdentifier, keychain: keychain)
            let box = try AES.GCM.SealedBox(combined: encryptedData)
            let plaintext = try AES.GCM.open(box, using: key)
            return try JSONDecoder().decode(RecentConversationsDigest.self, from: plaintext)
        }.value
    }

    /// Saves the conversation summaries digest to encrypted storage.
    func saveSummaries(_ digest: RecentConversationsDigest) async throws {
        let summaryFileURL = summaryFileURL
        let keyIdentifier = keyIdentifier
        let keychain = keychain

        try await Task.detached(priority: .userInitiated) {
            let encoded = try JSONEncoder().encode(digest)
            let key = try Self.getEncryptionKey(keyIdentifier: keyIdentifier, keychain: keychain)
            let sealed = try AES.GCM.seal(encoded, using: key)

            guard let combined = sealed.combined else {
                throw EncryptedMemoryStoreError.encodingFailed
            }

            try combined.write(to: summaryFileURL, options: .atomic)

            DiagnosticsLogger.log(
                .encryptedStore,
                level: .info,
                message: "✅ Saved conversation summaries",
                metadata: ["summaryCount": "\(digest.summaries.count)"]
            )
        }.value
    }

    /// Clears all conversation summaries.
    func clearSummaries() throws {
        if FileManager.default.fileExists(atPath: summaryFileURL.path) {
            try FileManager.default.removeItem(at: summaryFileURL)
        }
        DiagnosticsLogger.log(
            .encryptedStore,
            level: .info,
            message: "🧹 Cleared conversation summaries"
        )
    }

    // MARK: - Helpers

    private nonisolated static func getEncryptionKey(keyIdentifier: String, keychain: KeychainStoring) throws
        -> SymmetricKey
    {
        let flagKey = "\(keyIdentifier)_initialized"

        if let existing = try keychain.data(for: keyIdentifier) {
            return SymmetricKey(data: existing)
        }

        // Check if we previously had a key (flag exists but key is missing)
        if (try? keychain.string(for: flagKey)) != nil {
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "❌ Memory encryption key missing but initialization flag exists"
            )
            throw EncryptedMemoryStoreError.keyLost
        }

        // First-time setup: generate new key and set initialization flag
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try keychain.setData(keyData, for: keyIdentifier)
        try keychain.setString("1", for: flagKey)

        DiagnosticsLogger.log(
            .encryptedStore,
            level: .info,
            message: "🔑 Generated new memory encryption key"
        )

        return newKey
    }
}
