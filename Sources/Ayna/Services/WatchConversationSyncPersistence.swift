//
//  WatchConversationSyncPersistence.swift
//  ayna
//
//  Durable, atomic persistence for Watch conversation synchronization state.
//

import CryptoKit
import Foundation

enum WatchConversationSyncPersistenceLocations {
    static let directoryURL = RuntimeEnvironment.defaultApplicationSupportDirectoryURL
        .appendingPathComponent("WatchConnectivity", isDirectory: true)
}

final class WatchConversationSyncStateStore: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() throws -> WatchConversationSyncState? {
        try lock.withLock {
            try loadUnlocked()
        }
    }

    func load(orCreating initialState: WatchConversationSyncState) throws -> WatchConversationSyncState {
        try lock.withLock {
            if let state = try loadUnlocked() {
                return state
            }
            try saveUnlocked(initialState)
            return initialState
        }
    }

    @discardableResult
    func update(
        initialState: WatchConversationSyncState,
        _ mutation: (inout WatchConversationSyncState) -> Void
    ) throws -> WatchConversationSyncState {
        try lock.withLock {
            var state = try loadUnlocked() ?? initialState
            mutation(&state)
            try saveUnlocked(state)
            return state
        }
    }

    private func loadUnlocked() throws -> WatchConversationSyncState? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(WatchConversationSyncState.self, from: data)
    }

    private func saveUnlocked(_ state: WatchConversationSyncState) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}

enum WatchConversationClearOutcome: String, Codable, Equatable, Sendable {
    case pending
    case committed
    case rolledBack
}

final class WatchConversationClearJournalStore: @unchecked Sendable {
    private struct Entry: Codable {
        let transaction: WatchConversationClearTransaction
        var outcome: WatchConversationClearOutcome
    }

    private struct Record: Codable {
        var entries: [Entry]
    }

    private static let maximumEntryCount = 32

    private let fileURL: URL
    private let lock = NSLock()

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func recordPending(_ transaction: WatchConversationClearTransaction) throws {
        try lock.withLock {
            var record = try loadUnlocked()
            if let index = record.entries.firstIndex(where: { $0.transaction.id == transaction.id }) {
                record.entries[index] = Entry(transaction: transaction, outcome: .pending)
            } else {
                record.entries.append(Entry(transaction: transaction, outcome: .pending))
            }
            if record.entries.count > Self.maximumEntryCount {
                record.entries.removeFirst(record.entries.count - Self.maximumEntryCount)
            }
            try saveUnlocked(record)
        }
    }

    func recordOutcome(
        _ outcome: WatchConversationClearOutcome,
        for transactionId: UUID
    ) throws {
        try lock.withLock {
            var record = try loadUnlocked()
            guard let index = record.entries.firstIndex(where: {
                $0.transaction.id == transactionId
            }) else {
                return
            }
            record.entries[index].outcome = outcome
            try saveUnlocked(record)
        }
    }

    func outcome(for transactionId: UUID) throws -> WatchConversationClearOutcome? {
        try lock.withLock {
            try loadUnlocked().entries.first(where: {
                $0.transaction.id == transactionId
            })?.outcome
        }
    }

    func remove(transactionId: UUID) throws {
        try lock.withLock {
            var record = try loadUnlocked()
            let previousCount = record.entries.count
            record.entries.removeAll { $0.transaction.id == transactionId }
            guard record.entries.count != previousCount else { return }
            try saveUnlocked(record)
        }
    }

    private func loadUnlocked() throws -> Record {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Record(entries: [])
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(Record.self, from: data)
    }

    private func saveUnlocked(_ record: Record) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: .atomic)
    }
}

final class WatchConversationMutationInbox: @unchecked Sendable {
    enum PersistenceError: LocalizedError {
        case encryptionKeyMissing
        case encryptionFailed

        var errorDescription: String? {
            switch self {
            case .encryptionKeyMissing:
                "The Watch mutation inbox encryption key is missing."
            case .encryptionFailed:
                "Failed to encrypt the Watch mutation inbox."
            }
        }
    }

    private struct Record: Codable {
        var mutations: [WatchConversationMutation]
    }

    private static let defaultKeyIdentifier =
        "com.sertacozercan.ayna.watch.mutation-inbox-encryption-key"
    private static let keyCreationLock = NSLock()

    private let fileURL: URL
    private let keyIdentifier: String
    private let keychain: KeychainStoring
    private let lock = NSLock()
    private var cachedEncryptionKeyData: Data?

    init(
        fileURL: URL,
        keyIdentifier: String = WatchConversationMutationInbox.defaultKeyIdentifier,
        keychain: KeychainStoring = KeychainStorage.standard
    ) {
        self.fileURL = fileURL
        self.keyIdentifier = keyIdentifier
        self.keychain = keychain
    }

    func enqueue(_ mutation: WatchConversationMutation) throws {
        try lock.withLock {
            var record = try loadUnlocked()
            guard !record.mutations.contains(where: { $0.id == mutation.id }) else { return }
            record.mutations.append(mutation)
            try saveUnlocked(record)
        }
    }

    func load() throws -> [WatchConversationMutation] {
        try lock.withLock {
            try loadUnlocked().mutations
        }
    }

    func remove(id: UUID) throws {
        try lock.withLock {
            var record = try loadUnlocked()
            let previousCount = record.mutations.count
            record.mutations.removeAll { $0.id == id }
            guard record.mutations.count != previousCount else { return }
            try saveUnlocked(record)
        }
    }

    private func loadUnlocked() throws -> Record {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Record(mutations: [])
        }
        let encryptedData = try Data(contentsOf: fileURL)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        let encryptionKey = try encryptionKeyUnlocked()
        let plaintext = try AES.GCM.open(sealedBox, using: encryptionKey)
        return try JSONDecoder().decode(Record.self, from: plaintext)
    }

    private func saveUnlocked(_ record: Record) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let plaintext = try JSONEncoder().encode(record)
        let encryptionKey = try encryptionKeyUnlocked()
        let sealedBox = try AES.GCM.seal(plaintext, using: encryptionKey)
        guard let encryptedData = sealedBox.combined else {
            throw PersistenceError.encryptionFailed
        }
        try encryptedData.write(to: fileURL, options: .atomic)
    }

    private func encryptionKeyUnlocked() throws -> SymmetricKey {
        if let cachedEncryptionKeyData {
            return SymmetricKey(data: cachedEncryptionKeyData)
        }

        return try Self.keyCreationLock.withLock {
            if let existingKeyData = try keychain.data(for: keyIdentifier) {
                cachedEncryptionKeyData = existingKeyData
                return SymmetricKey(data: existingKeyData)
            }
            guard !FileManager.default.fileExists(atPath: fileURL.path) else {
                throw PersistenceError.encryptionKeyMissing
            }

            let newKey = SymmetricKey(size: .bits256)
            let newKeyData = newKey.withUnsafeBytes { Data($0) }
            try keychain.setData(newKeyData, for: keyIdentifier)
            cachedEncryptionKeyData = newKeyData
            return newKey
        }
    }
}
