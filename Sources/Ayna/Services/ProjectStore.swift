//
//  ProjectStore.swift
//  Ayna
//
//  Encrypted persistence for project metadata.
//

import CryptoKit
import Foundation
import os.log

final class ProjectStore: Sendable {
    nonisolated static let shared = ProjectStore()

    private let directoryURL: URL
    private let keyIdentifier: String
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
            self.directoryURL = baseDirectory.appendingPathComponent("Projects", isDirectory: true)
        }

        if !FileManager.default.fileExists(atPath: self.directoryURL.path) {
            try? FileManager.default.createDirectory(
                at: self.directoryURL, withIntermediateDirectories: true
            )
        }

        self.keyIdentifier = keyIdentifier
        encryptionKeyCache = EncryptionKeyCache(keyIdentifier: keyIdentifier, keychain: keychain)
    }

    private func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.encryptedStore, level: level, message: message, metadata: metadata)
    }

    func loadProjects() async throws -> [Project] {
        let directoryURL = directoryURL
        let keyCache = encryptionKeyCache

        return try await Task.detached(priority: .userInitiated) {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: directoryURL, includingPropertiesForKeys: nil
            )
            let encryptedFileURLs = fileURLs.filter { $0.pathExtension == "enc" }

            guard !encryptedFileURLs.isEmpty else {
                return []
            }

            let keyData = try keyCache.keyData()

            return await withTaskGroup(of: Project?.self) { group in
                for url in encryptedFileURLs {
                    group.addTask {
                        do {
                            return try Self.load(from: url, keyData: keyData)
                        } catch {
                            DiagnosticsLogger.log(
                                .encryptedStore,
                                level: .error,
                                message: "Failed to load project",
                                metadata: [
                                    "file": url.lastPathComponent,
                                    "error": error.localizedDescription
                                ]
                            )
                            return nil
                        }
                    }
                }

                var projects: [Project] = []
                for await project in group {
                    if let project {
                        projects.append(project)
                    }
                }
                return projects
            }
        }.value
    }

    func save(_ project: Project) async throws {
        let directoryURL = directoryURL
        let keyCache = encryptionKeyCache

        try await Task.detached(priority: .userInitiated) {
            let keyData = try keyCache.keyData()
            try Self.save(project, to: directoryURL, keyData: keyData)
        }.value
    }

    func delete(_ projectId: UUID) async throws {
        let directoryURL = directoryURL

        try await Task.detached(priority: .userInitiated) {
            let fileURL = directoryURL.appendingPathComponent("\(projectId.uuidString).enc")
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        }.value
    }

    func clear() throws {
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil
        )
        for url in fileURLs {
            try FileManager.default.removeItem(at: url)
        }
        log("Cleared encrypted project store")
    }

    func fileURL(for projectId: UUID) -> URL {
        directoryURL.appendingPathComponent("\(projectId.uuidString).enc")
    }

    private nonisolated static func load(from url: URL, keyData: Data) throws -> Project {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Project.self, from: plaintext)
    }

    private nonisolated static func save(
        _ project: Project,
        to directory: URL,
        keyData: Data
    ) throws {
        let encoded = try JSONEncoder().encode(project)
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        let fileURL = directory.appendingPathComponent("\(project.id.uuidString).enc")
        try combined.write(to: fileURL, options: .atomic)
    }
}
