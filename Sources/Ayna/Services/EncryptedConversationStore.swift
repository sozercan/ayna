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
    case clearBackupCleanupFailed(paths: [String])
    case clearCleanupPending(paths: [String])
    case clearRollbackFailed(paths: [String])
    case clearRecoveryRequired(paths: [String])
    case unsupportedClearSymbolicLink(path: String)

    var errorDescription: String? {
        switch self {
        case .keyLost:
            "Encryption key was lost. Previously encrypted conversations cannot be recovered. Please contact support if you need assistance."
        case let .clearBackupCleanupFailed(paths):
            "Conversations were cleared, but encrypted backup cleanup failed for: \(paths.joined(separator: ", "))."
        case let .clearCleanupPending(paths):
            "Encrypted backup cleanup is still pending for: \(paths.joined(separator: ", "))."
        case let .clearRollbackFailed(paths):
            "Conversation clearing could not be rolled back. Recovery is required for: \(paths.joined(separator: ", "))."
        case let .clearRecoveryRequired(paths):
            "Conversation storage is awaiting clear-transaction recovery for: \(paths.joined(separator: ", "))."
        case let .unsupportedClearSymbolicLink(path):
            "Conversation storage cannot be cleared safely while this path is a symbolic link: \(path)."
        }
    }

    var clearWasCommitted: Bool {
        if case .clearBackupCleanupFailed = self {
            return true
        }
        return false
    }

    var clearNeedsRecovery: Bool {
        switch self {
        case .clearRollbackFailed, .clearRecoveryRequired:
            true
        case .keyLost, .clearBackupCleanupFailed, .clearCleanupPending, .unsupportedClearSymbolicLink:
            false
        }
    }
}

struct PrivacyCleanupMarkerSnapshot: Sendable {
    fileprivate let markerFileNames: Set<String>

    var isEmpty: Bool {
        markerFileNames.isEmpty
    }

    var summaryCleanupToken: String {
        let markerData = Data(markerFileNames.sorted().joined(separator: "\0").utf8)
        return SHA256.hash(data: markerData).map { String(format: "%02x", $0) }.joined()
    }
}

enum PrivacyAttachmentCleanupPlan: Sendable {
    case completed
    case fileNames(Set<String>)
    case unknown
}

private struct PrivacyCleanupMarkerState: Codable {
    var attachmentFileNames: [String]?
    var attachmentCleanupCompleted = false
    var spotlightCleanupCompleted = false
    var summaryCleanupCompleted = false

    private enum CodingKeys: String, CodingKey {
        case attachmentFileNames
        case attachmentCleanupCompleted
        case spotlightCleanupCompleted
        case summaryCleanupCompleted
    }

    init(
        attachmentFileNames: [String]? = nil,
        attachmentCleanupCompleted: Bool = false,
        spotlightCleanupCompleted: Bool = false,
        summaryCleanupCompleted: Bool = false
    ) {
        self.attachmentFileNames = attachmentFileNames
        self.attachmentCleanupCompleted = attachmentCleanupCompleted
        self.spotlightCleanupCompleted = spotlightCleanupCompleted
        self.summaryCleanupCompleted = summaryCleanupCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        attachmentFileNames = try container.decodeIfPresent([String].self, forKey: .attachmentFileNames)
        attachmentCleanupCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .attachmentCleanupCompleted
        ) ?? false
        spotlightCleanupCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .spotlightCleanupCompleted
        ) ?? false
        summaryCleanupCompleted = try container.decodeIfPresent(
            Bool.self,
            forKey: .summaryCleanupCompleted
        ) ?? false
    }
}

final class EncryptedConversationStore: Sendable {
    nonisolated static let shared = EncryptedConversationStore()

    private let directoryURL: URL
    private let metadataDirectoryURL: URL
    private let searchIndexDirectoryURL: URL
    private let stagingDirectoryURL: URL
    private let legacyFileURL: URL
    private let keyIdentifier: String
    private let keychain: KeychainStoring
    private let backupRemovalOperation: @Sendable (URL) throws -> Void
    private let clearArtifactDirectoryContentsOperation: @Sendable (URL) throws -> [URL]
    private let moveOperation: @Sendable (URL, URL) throws -> Void
    private let encryptionKeyCache: EncryptionKeyCache
    private let sharedMutationState: SharedMutationState
    private let mutationLock: MutationLock
    private let searchIndexCache = SearchIndexCache()
    private let operationGenerations: OperationGenerationRegistry

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

    private struct FileVersion: Codable, Equatable, Sendable {
        let modificationDate: Date?
        let fileSize: Int?
    }

    private struct ConversationSearchIndex: Codable, Sendable {
        let id: UUID
        let sourceVersion: FileVersion
        let searchableFields: [String]
    }

    private struct PreparedConversationWrite: Sendable {
        let id: UUID
        let encryptedConversation: Data
        let encryptedMetadata: Data?
    }

    private struct StagedConversationWrite: Sendable {
        let id: UUID
        let conversationTemporaryURL: URL
        let metadataTemporaryURL: URL?
    }

    private final class MutationLock: @unchecked Sendable {
        private let lock = NSLock()

        func withLock<T>(_ operation: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try operation()
        }
    }

    private final class SearchIndexCache: @unchecked Sendable {
        static let maximumEntryCost = 4 * 1024 * 1024
        static let maximumTotalCost = 32 * 1024 * 1024

        struct Entry: Sendable {
            let fileVersion: FileVersion
            let searchableFields: [String]

            var cost: Int {
                searchableFields.reduce(into: 0) { $0 += $1.utf8.count }
            }
        }

        private let lock = NSLock()
        private let maximumCost: Int
        private let maximumEntryCount: Int
        private var entries: [UUID: Entry] = [:]
        private var leastToMostRecentlyUsed: [UUID] = []
        private var totalCost = 0

        init(maximumCost: Int = maximumTotalCost, maximumEntryCount: Int = 256) {
            self.maximumCost = maximumCost
            self.maximumEntryCount = maximumEntryCount
        }

        func entry(for conversationId: UUID) -> Entry? {
            lock.lock()
            defer { lock.unlock() }
            guard let entry = entries[conversationId] else { return nil }
            markRecentlyUsed(conversationId)
            return entry
        }

        func set(_ entry: Entry, for conversationId: UUID) {
            lock.lock()
            defer { lock.unlock() }

            removeLocked(conversationId)
            guard entry.cost <= maximumCost else { return }

            entries[conversationId] = entry
            leastToMostRecentlyUsed.append(conversationId)
            totalCost += entry.cost
            evictIfNeeded()
        }

        func remove(_ conversationId: UUID) {
            lock.lock()
            removeLocked(conversationId)
            lock.unlock()
        }

        func removeAll() {
            lock.lock()
            entries.removeAll()
            leastToMostRecentlyUsed.removeAll()
            totalCost = 0
            lock.unlock()
        }

        private func markRecentlyUsed(_ conversationId: UUID) {
            leastToMostRecentlyUsed.removeAll { $0 == conversationId }
            leastToMostRecentlyUsed.append(conversationId)
        }

        private func removeLocked(_ conversationId: UUID) {
            if let removed = entries.removeValue(forKey: conversationId) {
                totalCost -= removed.cost
            }
            leastToMostRecentlyUsed.removeAll { $0 == conversationId }
        }

        private func evictIfNeeded() {
            while totalCost > maximumCost || entries.count > maximumEntryCount {
                guard let leastRecentlyUsed = leastToMostRecentlyUsed.first else { break }
                removeLocked(leastRecentlyUsed)
            }
        }
    }

    private final class OperationGenerationRegistry: @unchecked Sendable {
        struct Generation: Equatable, Sendable {
            let global: UInt64
            let conversation: UInt64
        }

        private let lock = NSLock()
        private var globalGeneration: UInt64 = 0
        private var conversationGenerations: [UUID: UInt64] = [:]

        func currentGeneration(for conversationId: UUID) -> Generation {
            lock.lock()
            defer { lock.unlock() }
            return Generation(
                global: globalGeneration,
                conversation: conversationGenerations[conversationId] ?? 0
            )
        }

        @discardableResult
        func advanceGeneration(for conversationId: UUID) -> Generation {
            lock.lock()
            let nextGeneration = (conversationGenerations[conversationId] ?? 0) &+ 1
            conversationGenerations[conversationId] = nextGeneration
            let generation = Generation(
                global: globalGeneration,
                conversation: nextGeneration
            )
            lock.unlock()
            return generation
        }

        func advanceAllGenerations() {
            lock.lock()
            globalGeneration &+= 1
            conversationGenerations.removeAll()
            lock.unlock()
        }

        func currentGlobalGeneration() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return globalGeneration
        }

        func matchesGlobalGeneration(_ generation: UInt64) -> Bool {
            currentGlobalGeneration() == generation
        }

        func matches(_ generation: Generation, for conversationId: UUID) -> Bool {
            currentGeneration(for: conversationId) == generation
        }
    }

    private final class SharedMutationState: @unchecked Sendable {
        let mutationLock = MutationLock()
        let operationGenerations = OperationGenerationRegistry()
        var unresolvedClearBackupPaths: [String]?
        var pendingCommittedCleanupPaths: [String]?
        var privacyCleanupMarkerScanFailurePaths: [String]?
    }

    private final class WeakMutationState {
        weak var value: SharedMutationState?

        init(_ value: SharedMutationState) {
            self.value = value
        }
    }

    private final class MutationStateRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [String: WeakMutationState] = [:]

        func state(for directory: URL) -> SharedMutationState {
            let key = directory.standardizedFileURL.resolvingSymlinksInPath().path
            lock.lock()
            defer { lock.unlock() }

            if let existing = states[key]?.value {
                return existing
            }
            let state = SharedMutationState()
            states[key] = WeakMutationState(state)
            return state
        }
    }

    private final class StagingCleanupRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var cleanedParentPaths: Set<String> = []
        private var activeStagingPaths: Set<String> = []

        private func canonicalPath(for url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }

        func register(_ directory: URL) {
            lock.lock()
            activeStagingPaths.insert(canonicalPath(for: directory))
            lock.unlock()
        }

        func unregister(_ directory: URL) {
            lock.lock()
            activeStagingPaths.remove(canonicalPath(for: directory))
            lock.unlock()
        }

        func removeAbandonedDirectories(
            in parentDirectory: URL,
            onlyOncePerProcess: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            let parentPath = canonicalPath(for: parentDirectory)
            if onlyOncePerProcess, !cleanedParentPaths.insert(parentPath).inserted {
                return
            }

            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: parentDirectory,
                includingPropertiesForKeys: nil
            ) else {
                return
            }
            for url in urls {
                guard url.lastPathComponent.hasPrefix(".AynaConversationStaging-") else { continue }
                guard !activeStagingPaths.contains(canonicalPath(for: url)) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static let conversationClearBackupPrefix = ".AynaConversationClearBackup-"
    private static let legacyClearBackupPrefix = ".AynaLegacyClearBackup-"
    private static let clearCommitMarkerPrefix = ".AynaConversationClearCommitted-"
    private static let privacyCleanupMarkerPrefix = ".AynaConversationPrivacyCleanupPending-"
    private static let mutationStateRegistry = MutationStateRegistry()
    private static let stagingCleanupRegistry = StagingCleanupRegistry()

    nonisolated static func clearArtifactIdentifier(for directoryURL: URL) -> String {
        let canonicalPath = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func scopedClearArtifactPrefix(
        _ basePrefix: String,
        directoryURL: URL
    ) -> String {
        "\(basePrefix)\(clearArtifactIdentifier(for: directoryURL))-"
    }

    private nonisolated static func removeCommittedClearBackups(
        directoryURL: URL,
        conversationParentDirectory: URL,
        legacyParentDirectory: URL,
        directoryContentsOperation: @Sendable (URL) throws -> [URL],
        removeOperation: @Sendable (URL) throws -> Void
    ) throws -> [String] {
        let urls = try clearArtifactDirectoryContents(
            at: conversationParentDirectory,
            directoryContentsOperation: directoryContentsOperation
        )

        let conversationBackupPrefix = scopedClearArtifactPrefix(
            conversationClearBackupPrefix,
            directoryURL: directoryURL
        )
        let legacyBackupPrefix = scopedClearArtifactPrefix(
            legacyClearBackupPrefix,
            directoryURL: directoryURL
        )
        let commitMarkerPrefix = scopedClearArtifactPrefix(
            clearCommitMarkerPrefix,
            directoryURL: directoryURL
        )
        let privacyCleanupMarkerPrefix = scopedClearArtifactPrefix(
            privacyCleanupMarkerPrefix,
            directoryURL: directoryURL
        )
        var failedBackupPaths: [String] = []
        for markerURL in urls where markerURL.lastPathComponent.hasPrefix(commitMarkerPrefix) {
            let transactionId = String(markerURL.lastPathComponent.dropFirst(commitMarkerPrefix.count))
            guard !transactionId.isEmpty else { continue }
            let backupURLs = [
                conversationParentDirectory.appendingPathComponent(
                    "\(conversationBackupPrefix)\(transactionId)",
                    isDirectory: true
                ),
                legacyParentDirectory.appendingPathComponent("\(legacyBackupPrefix)\(transactionId)")
            ]
            var cleanupSucceeded = true
            for backupURL in backupURLs where FileManager.default.fileExists(atPath: backupURL.path) {
                do {
                    try removeOperation(backupURL)
                } catch {
                    cleanupSucceeded = false
                    failedBackupPaths.append(backupURL.path)
                    DiagnosticsLogger.log(
                        .encryptedStore,
                        level: .error,
                        message: "Failed to remove committed conversation clear backup during startup",
                        metadata: [
                            "error": error.localizedDescription,
                            "backup": backupURL.path
                        ]
                    )
                }
            }
            if cleanupSucceeded {
                let privacyMarkerURL = conversationParentDirectory.appendingPathComponent(
                    "\(privacyCleanupMarkerPrefix)\(transactionId)"
                )
                if !FileManager.default.fileExists(atPath: privacyMarkerURL.path) {
                    try? FileManager.default.removeItem(at: markerURL)
                }
            }
        }
        return failedBackupPaths
    }

    private nonisolated static func recoverUncommittedClearBackup(
        directoryURL: URL,
        legacyFileURL: URL,
        directoryContentsOperation: @Sendable (URL) throws -> [URL]
    ) throws -> [String] {
        let conversationParentDirectory = directoryURL.deletingLastPathComponent()
        let legacyParentDirectory = legacyFileURL.deletingLastPathComponent()
        let conversationBackupPrefix = scopedClearArtifactPrefix(
            conversationClearBackupPrefix,
            directoryURL: directoryURL
        )
        let legacyBackupPrefix = scopedClearArtifactPrefix(
            legacyClearBackupPrefix,
            directoryURL: directoryURL
        )
        let commitMarkerPrefix = scopedClearArtifactPrefix(
            clearCommitMarkerPrefix,
            directoryURL: directoryURL
        )
        let privacyCleanupMarkerPrefix = scopedClearArtifactPrefix(
            privacyCleanupMarkerPrefix,
            directoryURL: directoryURL
        )
        let conversationParentItems = try clearArtifactDirectoryContents(
            at: conversationParentDirectory,
            directoryContentsOperation: directoryContentsOperation
        )
        let legacyParentItems: [URL] = if legacyParentDirectory == conversationParentDirectory {
            conversationParentItems
        } else {
            try clearArtifactDirectoryContents(
                at: legacyParentDirectory,
                directoryContentsOperation: directoryContentsOperation
            )
        }

        let committedTransactionIds = Set(conversationParentItems.compactMap { url -> String? in
            guard url.lastPathComponent.hasPrefix(commitMarkerPrefix) else { return nil }
            return String(url.lastPathComponent.dropFirst(commitMarkerPrefix.count))
        })
        let rollbackBackups = conversationParentItems.filter { url in
            guard url.lastPathComponent.hasPrefix(conversationBackupPrefix) else { return false }
            let transactionId = String(url.lastPathComponent.dropFirst(conversationBackupPrefix.count))
            return !committedTransactionIds.contains(transactionId)
        }.sorted(by: newestFileFirst)
        let legacyRollbackBackups = legacyParentItems.filter { url in
            guard url.lastPathComponent.hasPrefix(legacyBackupPrefix) else { return false }
            let transactionId = String(url.lastPathComponent.dropFirst(legacyBackupPrefix.count))
            return !committedTransactionIds.contains(transactionId)
        }.sorted(by: newestFileFirst)
        for markerURL in conversationParentItems
            where markerURL.lastPathComponent.hasPrefix(privacyCleanupMarkerPrefix)
        {
            let transactionId = String(
                markerURL.lastPathComponent.dropFirst(privacyCleanupMarkerPrefix.count)
            )
            if !committedTransactionIds.contains(transactionId) {
                try? FileManager.default.removeItem(at: markerURL)
            }
        }

        var recoveredTransactionIds: Set<String> = []
        if let rollbackBackup = rollbackBackups.first,
           isEmptyInitializedStoreDirectory(directoryURL)
        {
            let transactionId = String(
                rollbackBackup.lastPathComponent.dropFirst(conversationBackupPrefix.count)
            )
            do {
                if FileManager.default.fileExists(atPath: directoryURL.path) {
                    try FileManager.default.removeItem(at: directoryURL)
                }
                try FileManager.default.moveItem(at: rollbackBackup, to: directoryURL)
                recoveredTransactionIds.insert(transactionId)

                let matchingLegacyBackup = legacyRollbackBackups.first { url in
                    url.lastPathComponent == "\(legacyBackupPrefix)\(transactionId)"
                }
                if let matchingLegacyBackup,
                   !FileManager.default.fileExists(atPath: legacyFileURL.path)
                {
                    try FileManager.default.moveItem(at: matchingLegacyBackup, to: legacyFileURL)
                }
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .info,
                    message: "Recovered interrupted conversation clear transaction",
                    metadata: ["transactionId": transactionId]
                )
            } catch {
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .error,
                    message: "Failed to recover interrupted conversation clear transaction",
                    metadata: [
                        "error": error.localizedDescription,
                        "backup": rollbackBackup.path
                    ]
                )
            }
        }

        if recoveredTransactionIds.isEmpty,
           !FileManager.default.fileExists(atPath: legacyFileURL.path),
           let standaloneLegacyBackup = legacyRollbackBackups.first
        {
            do {
                try FileManager.default.moveItem(at: standaloneLegacyBackup, to: legacyFileURL)
                let transactionId = String(
                    standaloneLegacyBackup.lastPathComponent.dropFirst(legacyBackupPrefix.count)
                )
                recoveredTransactionIds.insert(transactionId)
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .info,
                    message: "Recovered interrupted legacy conversation clear transaction",
                    metadata: ["transactionId": transactionId]
                )
            } catch {
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .error,
                    message: "Failed to recover interrupted legacy clear transaction",
                    metadata: [
                        "error": error.localizedDescription,
                        "backup": standaloneLegacyBackup.path
                    ]
                )
            }
        }

        return (rollbackBackups + legacyRollbackBackups)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }

    private nonisolated static func clearArtifactDirectoryContents(
        at directoryURL: URL,
        directoryContentsOperation: @Sendable (URL) throws -> [URL]
    ) throws -> [URL] {
        do {
            return try directoryContentsOperation(directoryURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return []
        }
    }

    private nonisolated static func newestFileFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsDate = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let rhsDate = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
    }

    private nonisolated static func isEmptyInitializedStoreDirectory(_ directoryURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return true }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        for url in urls {
            guard url.lastPathComponent == "Metadata" || url.lastPathComponent == "SearchIndex",
                  let nestedItems = try? FileManager.default.contentsOfDirectory(
                      at: url,
                      includingPropertiesForKeys: nil
                  ),
                  nestedItems.isEmpty
            else {
                return false
            }
        }
        return true
    }

    private var scopedPrivacyCleanupMarkerPrefix: String {
        Self.scopedClearArtifactPrefix(
            Self.privacyCleanupMarkerPrefix,
            directoryURL: directoryURL
        )
    }

    private var scopedCommitMarkerPrefix: String {
        Self.scopedClearArtifactPrefix(
            Self.clearCommitMarkerPrefix,
            directoryURL: directoryURL
        )
    }

    private func privacyCleanupMarkerURLsThrowing() throws -> [URL] {
        let parentDirectory = directoryURL.deletingLastPathComponent()
        do {
            let urls = try Self.clearArtifactDirectoryContents(
                at: parentDirectory,
                directoryContentsOperation: clearArtifactDirectoryContentsOperation
            )
            sharedMutationState.privacyCleanupMarkerScanFailurePaths = nil
            return urls.filter { $0.lastPathComponent.hasPrefix(scopedPrivacyCleanupMarkerPrefix) }
        } catch {
            sharedMutationState.privacyCleanupMarkerScanFailurePaths = [parentDirectory.path]
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "Failed to scan pending privacy cleanup markers",
                metadata: [
                    "error": error.localizedDescription,
                    "directory": parentDirectory.path,
                ]
            )
            throw error
        }
    }

    private func privacyCleanupMarkerURLs() -> [URL] {
        (try? privacyCleanupMarkerURLsThrowing()) ?? []
    }

    private func privacyCleanupMarkerURL(for fileName: String) -> URL? {
        guard fileName.hasPrefix(scopedPrivacyCleanupMarkerPrefix) else { return nil }
        return directoryURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    private func privacyCleanupMarkerState(at markerURL: URL) -> PrivacyCleanupMarkerState {
        guard let data = try? Data(contentsOf: markerURL), !data.isEmpty,
              let state = try? JSONDecoder().decode(PrivacyCleanupMarkerState.self, from: data)
        else {
            return PrivacyCleanupMarkerState()
        }
        return state
    }

    private func savePrivacyCleanupMarkerState(
        _ state: PrivacyCleanupMarkerState,
        at markerURL: URL
    ) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: markerURL, options: .atomic)
    }

    func hasPendingPrivacyCleanup() -> Bool {
        mutationLock.withLock {
            do {
                return try !privacyCleanupMarkerURLsThrowing().isEmpty
            } catch {
                return true
            }
        }
    }

    func pendingPrivacyCleanupMarkerSnapshotThrowing() throws -> PrivacyCleanupMarkerSnapshot {
        try mutationLock.withLock {
            try PrivacyCleanupMarkerSnapshot(
                markerFileNames: Set(privacyCleanupMarkerURLsThrowing().map(\.lastPathComponent))
            )
        }
    }

    func pendingPrivacyCleanupMarkerSnapshot() -> PrivacyCleanupMarkerSnapshot {
        mutationLock.withLock {
            PrivacyCleanupMarkerSnapshot(
                markerFileNames: Set(privacyCleanupMarkerURLs().map(\.lastPathComponent))
            )
        }
    }

    func recordAttachmentCleanupSnapshot(
        _ snapshot: AttachmentCleanupSnapshot,
        for markerSnapshot: PrivacyCleanupMarkerSnapshot
    ) throws {
        try mutationLock.withLock {
            for markerFileName in markerSnapshot.markerFileNames {
                guard let markerURL = privacyCleanupMarkerURL(for: markerFileName),
                      FileManager.default.fileExists(atPath: markerURL.path)
                else {
                    continue
                }
                var state = privacyCleanupMarkerState(at: markerURL)
                if state.attachmentFileNames == nil {
                    state.attachmentFileNames = snapshot.fileNames.sorted()
                    try savePrivacyCleanupMarkerState(state, at: markerURL)
                }
            }
        }
    }

    func attachmentCleanupPlan(
        for markerSnapshot: PrivacyCleanupMarkerSnapshot
    ) -> PrivacyAttachmentCleanupPlan {
        mutationLock.withLock {
            var pendingFileNames = Set<String>()
            var foundPendingMarker = false
            for markerFileName in markerSnapshot.markerFileNames {
                guard let markerURL = privacyCleanupMarkerURL(for: markerFileName),
                      FileManager.default.fileExists(atPath: markerURL.path)
                else {
                    continue
                }
                let state = privacyCleanupMarkerState(at: markerURL)
                guard !state.attachmentCleanupCompleted else { continue }
                foundPendingMarker = true
                guard let attachmentFileNames = state.attachmentFileNames else {
                    return .unknown
                }
                pendingFileNames.formUnion(attachmentFileNames)
            }
            if foundPendingMarker {
                return .fileNames(pendingFileNames)
            }
            return .completed
        }
    }

    func markAttachmentCleanupCompleted(
        for markerSnapshot: PrivacyCleanupMarkerSnapshot
    ) throws {
        try mutationLock.withLock {
            for markerFileName in markerSnapshot.markerFileNames {
                guard let markerURL = privacyCleanupMarkerURL(for: markerFileName),
                      FileManager.default.fileExists(atPath: markerURL.path)
                else {
                    continue
                }
                var state = privacyCleanupMarkerState(at: markerURL)
                state.attachmentCleanupCompleted = true
                try savePrivacyCleanupMarkerState(state, at: markerURL)
            }
        }
    }

    func isSpotlightCleanupCompleted(
        for markerSnapshot: PrivacyCleanupMarkerSnapshot
    ) -> Bool {
        mutationLock.withLock {
            var foundMarker = false
            for markerFileName in markerSnapshot.markerFileNames {
                guard let markerURL = privacyCleanupMarkerURL(for: markerFileName),
                      FileManager.default.fileExists(atPath: markerURL.path)
                else {
                    continue
                }
                foundMarker = true
                if !privacyCleanupMarkerState(at: markerURL).spotlightCleanupCompleted {
                    return false
                }
            }
            return foundMarker
        }
    }

    func markSpotlightCleanupCompleted(
        for markerSnapshot: PrivacyCleanupMarkerSnapshot
    ) throws {
        try mutationLock.withLock {
            for markerFileName in markerSnapshot.markerFileNames {
                guard let markerURL = privacyCleanupMarkerURL(for: markerFileName),
                      FileManager.default.fileExists(atPath: markerURL.path)
                else {
                    continue
                }
                var state = privacyCleanupMarkerState(at: markerURL)
                state.spotlightCleanupCompleted = true
                try savePrivacyCleanupMarkerState(state, at: markerURL)
            }
        }
    }

    func isSummaryCleanupCompleted(
        for markerSnapshot: PrivacyCleanupMarkerSnapshot
    ) -> Bool {
        mutationLock.withLock {
            var foundMarker = false
            for markerFileName in markerSnapshot.markerFileNames {
                guard let markerURL = privacyCleanupMarkerURL(for: markerFileName),
                      FileManager.default.fileExists(atPath: markerURL.path)
                else {
                    continue
                }
                foundMarker = true
                if !privacyCleanupMarkerState(at: markerURL).summaryCleanupCompleted {
                    return false
                }
            }
            return foundMarker
        }
    }

    func markSummaryCleanupCompleted(
        for markerSnapshot: PrivacyCleanupMarkerSnapshot
    ) throws {
        try mutationLock.withLock {
            for markerFileName in markerSnapshot.markerFileNames {
                guard let markerURL = privacyCleanupMarkerURL(for: markerFileName),
                      FileManager.default.fileExists(atPath: markerURL.path)
                else {
                    continue
                }
                var state = privacyCleanupMarkerState(at: markerURL)
                state.summaryCleanupCompleted = true
                try savePrivacyCleanupMarkerState(state, at: markerURL)
            }
        }
    }

    func clearPendingPrivacyCleanup(_ snapshot: PrivacyCleanupMarkerSnapshot) throws {
        try mutationLock.withLock {
            let parentDirectory = directoryURL.deletingLastPathComponent()
            for markerFileName in snapshot.markerFileNames {
                guard markerFileName.hasPrefix(scopedPrivacyCleanupMarkerPrefix) else { continue }
                let transactionId = String(markerFileName.dropFirst(scopedPrivacyCleanupMarkerPrefix.count))
                let markerURL = parentDirectory.appendingPathComponent(markerFileName)
                do {
                    try FileManager.default.removeItem(at: markerURL)
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // The privacy marker was already acknowledged by another cleanup pass.
                }
                guard !transactionId.isEmpty else { continue }
                let commitMarkerURL = parentDirectory.appendingPathComponent(
                    "\(scopedCommitMarkerPrefix)\(transactionId)"
                )
                let conversationBackupURL = parentDirectory.appendingPathComponent(
                    "\(Self.scopedClearArtifactPrefix(Self.conversationClearBackupPrefix, directoryURL: directoryURL))\(transactionId)",
                    isDirectory: true
                )
                let legacyBackupURL = legacyFileURL.deletingLastPathComponent().appendingPathComponent(
                    "\(Self.scopedClearArtifactPrefix(Self.legacyClearBackupPrefix, directoryURL: directoryURL))\(transactionId)"
                )
                let transactionBackupPaths = Set([
                    conversationBackupURL.path,
                    legacyBackupURL.path
                ])
                let hasPendingBackup = FileManager.default.fileExists(atPath: conversationBackupURL.path)
                    || FileManager.default.fileExists(atPath: legacyBackupURL.path)
                    || (sharedMutationState.pendingCommittedCleanupPaths?.contains {
                        transactionBackupPaths.contains($0)
                    } ?? false)
                if !hasPendingBackup {
                    do {
                        try FileManager.default.removeItem(at: commitMarkerURL)
                    } catch let error as CocoaError where error.code == .fileNoSuchFile {
                        continue
                    }
                }
            }
        }
    }

    func clearPendingPrivacyCleanup() throws {
        try clearPendingPrivacyCleanup(pendingPrivacyCleanupMarkerSnapshotThrowing())
    }

    init(
        directoryURL: URL? = nil,
        legacyFileURL: URL? = nil,
        keyIdentifier: String = "conversation_encryption_key",
        keychain: KeychainStoring = KeychainStorage.standard,
        backupRemovalOperation: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
        clearArtifactDirectoryContentsOperation: @escaping @Sendable (URL) throws -> [URL] = { directoryURL in
            try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )
        },
        moveOperation: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
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

        searchIndexDirectoryURL = self.directoryURL.appendingPathComponent("SearchIndex", isDirectory: true)
        if !FileManager.default.fileExists(atPath: searchIndexDirectoryURL.path) {
            try? FileManager.default.createDirectory(
                at: searchIndexDirectoryURL, withIntermediateDirectories: true
            )
        }

        stagingDirectoryURL = self.directoryURL.deletingLastPathComponent().appendingPathComponent(
            ".AynaConversationStaging-\(UUID().uuidString)",
            isDirectory: true
        )

        self.legacyFileURL = legacyFileURL ?? baseDirectory.appendingPathComponent("conversations.enc")
        self.keyIdentifier = keyIdentifier
        self.keychain = keychain
        self.backupRemovalOperation = backupRemovalOperation
        self.clearArtifactDirectoryContentsOperation = clearArtifactDirectoryContentsOperation
        self.moveOperation = moveOperation
        encryptionKeyCache = EncryptionKeyCache(keyIdentifier: keyIdentifier, keychain: keychain)
        let mutationState = Self.mutationStateRegistry.state(for: self.directoryURL)
        sharedMutationState = mutationState
        mutationLock = mutationState.mutationLock
        operationGenerations = mutationState.operationGenerations
        let stagingParentDirectory = self.directoryURL.deletingLastPathComponent()
        let legacyParentDirectory = self.legacyFileURL.deletingLastPathComponent()
        mutationLock.withLock {
            do {
                let failedCommittedCleanupPaths = try Self.removeCommittedClearBackups(
                    directoryURL: self.directoryURL,
                    conversationParentDirectory: stagingParentDirectory,
                    legacyParentDirectory: legacyParentDirectory,
                    directoryContentsOperation: clearArtifactDirectoryContentsOperation,
                    removeOperation: backupRemovalOperation
                )
                mutationState.pendingCommittedCleanupPaths = failedCommittedCleanupPaths.isEmpty
                    ? nil
                    : failedCommittedCleanupPaths
                let unresolvedBackupPaths = try Self.recoverUncommittedClearBackup(
                    directoryURL: self.directoryURL,
                    legacyFileURL: self.legacyFileURL,
                    directoryContentsOperation: clearArtifactDirectoryContentsOperation
                )
                mutationState.unresolvedClearBackupPaths = unresolvedBackupPaths.isEmpty
                    ? nil
                    : unresolvedBackupPaths
            } catch {
                mutationState.pendingCommittedCleanupPaths = nil
                mutationState.unresolvedClearBackupPaths = Array(Set([
                    stagingParentDirectory.path,
                    legacyParentDirectory.path,
                ])).sorted()
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .error,
                    message: "Failed to scan conversation clear recovery artifacts",
                    metadata: [
                        "error": error.localizedDescription,
                        "directory": stagingParentDirectory.path,
                    ]
                )
            }
            _ = privacyCleanupMarkerURLs()
            try? Self.ensureDirectoryExists(self.directoryURL)
            try? Self.ensureDirectoryExists(metadataDirectoryURL)
            try? Self.ensureDirectoryExists(searchIndexDirectoryURL)
        }
        Self.stagingCleanupRegistry.register(stagingDirectoryURL)
        Self.stagingCleanupRegistry.removeAbandonedDirectories(
            in: stagingParentDirectory,
            onlyOncePerProcess: true
        )
        if legacyParentDirectory != stagingParentDirectory {
            Self.stagingCleanupRegistry.removeAbandonedDirectories(
                in: legacyParentDirectory,
                onlyOncePerProcess: true
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
        Self.stagingCleanupRegistry.unregister(stagingDirectoryURL)
    }

    private func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.encryptedStore, level: level, message: message, metadata: metadata)
    }

    private func ensureClearRecoveryResolved() throws {
        try mutationLock.withLock {
            if let unresolvedBackupPaths = sharedMutationState.unresolvedClearBackupPaths {
                throw EncryptedStoreError.clearRecoveryRequired(paths: unresolvedBackupPaths)
            }
            if let pendingCleanupPaths = sharedMutationState.pendingCommittedCleanupPaths {
                throw EncryptedStoreError.clearBackupCleanupFailed(paths: pendingCleanupPaths)
            }
            if let scanFailurePaths = sharedMutationState.privacyCleanupMarkerScanFailurePaths {
                throw EncryptedStoreError.clearRecoveryRequired(paths: scanFailurePaths)
            }
        }
    }

    func loadConversations() async throws -> [Conversation] {
        try ensureClearRecoveryResolved()
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL
        let stagingDirectoryURL = stagingDirectoryURL
        let legacyFileURL = legacyFileURL
        let keyCache = encryptionKeyCache
        let mutationLock = mutationLock
        let operationGenerations = operationGenerations
        let loadGeneration = operationGenerations.currentGlobalGeneration()

        return try await Task.detached(priority: .userInitiated) {
            // 1. Check for legacy file and migrate if needed
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                let keyData = try keyCache.keyData()
                DiagnosticsLogger.log(
                    .encryptedStore, level: .info, message: "Found legacy conversation file, migrating..."
                )
                do {
                    let conversations = try Self.deduplicatedLegacyConversations(
                        Self.loadLegacyFile(at: legacyFileURL, keyData: keyData)
                    )
                    for conversation in conversations {
                        let committed = try Self.migrateLegacyConversation(
                            conversation,
                            keyData: keyData,
                            directory: directoryURL,
                            metadataDirectory: metadataDirectoryURL,
                            stagingDirectory: stagingDirectoryURL,
                            mutationLock: mutationLock,
                            operationGenerations: operationGenerations,
                            expectedGlobalGeneration: loadGeneration
                        )
                        guard committed != nil else { return [] }
                    }
                    let migrationFinished = try mutationLock.withLock { () -> Bool in
                        guard operationGenerations.matchesGlobalGeneration(loadGeneration) else {
                            return false
                        }
                        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                            try FileManager.default.removeItem(at: legacyFileURL)
                        }
                        return true
                    }
                    guard migrationFinished else { return [] }
                    DiagnosticsLogger.log(.encryptedStore, level: .info, message: "Migration complete")
                    return try await Self.loadCanonicalConversations(
                        in: directoryURL,
                        keyData: keyData,
                        mutationLock: mutationLock,
                        operationGenerations: operationGenerations
                    )
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

            let conversations = await withTaskGroup(of: Conversation?.self) { group in
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
            guard operationGenerations.matchesGlobalGeneration(loadGeneration) else { return [] }
            return conversations
        }.value
    }

    func loadConversationMetadata() async throws -> [ConversationMetadata] {
        try ensureClearRecoveryResolved()
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL
        let searchIndexDirectoryURL = searchIndexDirectoryURL
        let stagingDirectoryURL = stagingDirectoryURL
        let legacyFileURL = legacyFileURL
        let keyCache = encryptionKeyCache
        let mutationLock = mutationLock
        let operationGenerations = operationGenerations
        let loadGeneration = operationGenerations.currentGlobalGeneration()

        return try await Task.detached(priority: .userInitiated) {
            // Keep metadata loading complete for legacy users. The first metadata load
            // migrates just like loadConversations(); subsequent loads can read small
            // sidecar records instead of full message histories.
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                let keyData = try keyCache.keyData()
                let conversations = try Self.deduplicatedLegacyConversations(
                    Self.loadLegacyFile(at: legacyFileURL, keyData: keyData)
                )
                for conversation in conversations {
                    let committed = try Self.migrateLegacyConversation(
                        conversation,
                        keyData: keyData,
                        directory: directoryURL,
                        metadataDirectory: metadataDirectoryURL,
                        stagingDirectory: stagingDirectoryURL,
                        mutationLock: mutationLock,
                        operationGenerations: operationGenerations,
                        expectedGlobalGeneration: loadGeneration
                    )
                    guard committed != nil else { return [] }
                }
                let migrationFinished = try mutationLock.withLock { () -> Bool in
                    guard operationGenerations.matchesGlobalGeneration(loadGeneration) else {
                        return false
                    }
                    if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                        try FileManager.default.removeItem(at: legacyFileURL)
                    }
                    return true
                }
                guard migrationFinished else { return [] }
                return try await Self.loadCanonicalConversations(
                    in: directoryURL,
                    keyData: keyData,
                    mutationLock: mutationLock,
                    operationGenerations: operationGenerations
                )
                .map(ConversationMetadata.init(conversation:))
                .sorted { $0.updatedAt > $1.updatedAt }
            }

            let conversationFileURLsById = try Self.conversationFileURLsById(in: directoryURL)
            let validConversationIds = Set(conversationFileURLsById.keys)
            Self.removeOrphanedSearchIndexes(
                in: searchIndexDirectoryURL,
                validConversationIds: validConversationIds
            )
            guard !conversationFileURLsById.isEmpty else {
                return []
            }
            let conversationGenerations = conversationFileURLsById.keys.reduce(into: [:]) { generations, id in
                generations[id] = operationGenerations.currentGeneration(for: id)
            }
            let conversationFileVersions = conversationFileURLsById.reduce(into: [UUID: FileVersion]()) { versions, pair in
                if let version = Self.fileVersion(at: pair.value) {
                    versions[pair.key] = version
                }
            }

            let keyData = try keyCache.keyData()
            let metadataFileURLsById = try Self.metadataFileURLsById(in: metadataDirectoryURL)

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
                      || Self.sidecarIsOlderThanConversation(
                          sidecarURL: metadataURL,
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
                keyData: keyData
            )

            guard operationGenerations.matchesGlobalGeneration(loadGeneration) else { return [] }

            var validMetadata: [UUID: ConversationMetadata] = [:]
            let metadataPairs = currentSidecarMetadata.map { ($0.key, $0.value) }
                + backfilledMetadata.map { ($0.key, $0.value) }
            for (id, initialMetadata) in metadataPairs {
                try Task.checkCancellation()
                guard var generation = conversationGenerations[id],
                      let conversationURL = conversationFileURLsById[id],
                      var sourceVersion = conversationFileVersions[id]
                else {
                    continue
                }

                var metadata = initialMetadata
                var shouldPersistSidecar = backfilledMetadata[id] != nil
                let currentVersion = Self.fileVersion(at: conversationURL)
                if !operationGenerations.matches(generation, for: id)
                    || sourceVersion != currentVersion
                {
                    guard let refreshed = try Self.loadStableFullMetadata(
                        conversationURL: conversationURL,
                        keyData: keyData
                    ) else {
                        continue
                    }
                    metadata = refreshed.metadata
                    sourceVersion = refreshed.sourceVersion
                    generation = operationGenerations.currentGeneration(for: id)
                    shouldPersistSidecar = true
                }

                var committed = try Self.commitMetadataCandidate(
                    metadata,
                    sourceVersion: sourceVersion,
                    shouldPersistSidecar: shouldPersistSidecar,
                    conversationId: id,
                    conversationURL: conversationURL,
                    metadataDirectory: metadataDirectoryURL,
                    stagingDirectory: stagingDirectoryURL,
                    keyData: keyData,
                    mutationLock: mutationLock,
                    operationGenerations: operationGenerations,
                    expectedGeneration: generation,
                    expectedGlobalGeneration: loadGeneration
                )

                if !committed,
                   operationGenerations.matchesGlobalGeneration(loadGeneration),
                   let refreshed = try Self.loadStableFullMetadata(
                       conversationURL: conversationURL,
                       keyData: keyData
                   )
                {
                    metadata = refreshed.metadata
                    generation = operationGenerations.currentGeneration(for: id)
                    committed = try Self.commitMetadataCandidate(
                        metadata,
                        sourceVersion: refreshed.sourceVersion,
                        shouldPersistSidecar: true,
                        conversationId: id,
                        conversationURL: conversationURL,
                        metadataDirectory: metadataDirectoryURL,
                        stagingDirectory: stagingDirectoryURL,
                        keyData: keyData,
                        mutationLock: mutationLock,
                        operationGenerations: operationGenerations,
                        expectedGeneration: generation,
                        expectedGlobalGeneration: loadGeneration
                    )
                }

                if committed {
                    validMetadata[id] = metadata
                }
            }

            guard operationGenerations.matchesGlobalGeneration(loadGeneration) else { return [] }
            return validMetadata.values.sorted { $0.updatedAt > $1.updatedAt }
        }.value
    }

    func loadConversation(id conversationId: UUID) async throws -> Conversation? {
        try ensureClearRecoveryResolved()
        guard let fileURL = try mutationLock.withLock({
            try Self.conversationFileURLsById(in: directoryURL)[conversationId]
        }) else {
            return nil
        }
        let keyCache = encryptionKeyCache
        let mutationLock = mutationLock
        let operationGenerations = operationGenerations

        while true {
            try Task.checkCancellation()
            let expectedGeneration = operationGenerations.currentGeneration(for: conversationId)
            guard let expectedVersion = Self.fileVersion(at: fileURL) else { return nil }
            let loadTask = Task.detached(priority: .userInitiated) { () throws -> Conversation in
                try Task.checkCancellation()
                let keyData = try keyCache.keyData()
                try Task.checkCancellation()
                return try Self.loadCancellable(from: fileURL, keyData: keyData)
            }

            do {
                let conversation = try await withTaskCancellationHandler {
                    do {
                        try Task.checkCancellation()
                        let conversation = try await loadTask.value
                        try Task.checkCancellation()
                        return conversation
                    } catch is CancellationError {
                        loadTask.cancel()
                        _ = try? await loadTask.value
                        throw CancellationError()
                    }
                } onCancel: {
                    loadTask.cancel()
                }

                let isCurrent = mutationLock.withLock {
                    operationGenerations.matches(expectedGeneration, for: conversationId)
                        && Self.fileVersion(at: fileURL) == expectedVersion
                }
                if isCurrent {
                    return conversation
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let generationChanged = mutationLock.withLock {
                    !operationGenerations.matches(expectedGeneration, for: conversationId)
                        || Self.fileVersion(at: fileURL) != expectedVersion
                }
                guard generationChanged else { throw error }
            }

            await Task.yield()
        }
    }

    func conversationIdsMatchingSearch(
        query: String,
        candidateIds: Set<UUID>
    ) async throws -> Set<UUID> {
        try ensureClearRecoveryResolved()
        guard !query.isEmpty, !candidateIds.isEmpty else { return [] }
        return try await searchConversationIds(
            query: query,
            candidateIds: candidateIds,
            priority: .userInitiated,
            persistBuiltIndexes: true
        )
    }

    func warmConversationSearchIndex(candidateIds: Set<UUID>) async throws {
        try ensureClearRecoveryResolved()
        let searchIndexDirectoryURL = searchIndexDirectoryURL
        let mutationLock = mutationLock
        let searchIndexCache = searchIndexCache
        let pruneTask = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try mutationLock.withLock {
                try Task.checkCancellation()
                Self.prunePersistedSearchIndexes(
                    in: searchIndexDirectoryURL,
                    keeping: candidateIds,
                    searchIndexCache: searchIndexCache
                )
            }
        }
        try await withTaskCancellationHandler {
            try await pruneTask.value
        } onCancel: {
            pruneTask.cancel()
        }
        guard !candidateIds.isEmpty else { return }
        for conversationId in candidateIds {
            searchIndexCache.remove(conversationId)
        }
        _ = try await searchConversationIds(
            query: "",
            candidateIds: candidateIds,
            priority: .utility,
            persistBuiltIndexes: true
        )
    }

    private func searchConversationIds(
        query: String,
        candidateIds: Set<UUID>,
        priority: TaskPriority,
        persistBuiltIndexes: Bool
    ) async throws -> Set<UUID> {
        let directoryURL = directoryURL
        let searchIndexDirectoryURL = searchIndexDirectoryURL
        let stagingDirectoryURL = stagingDirectoryURL
        let keyCache = encryptionKeyCache
        let mutationLock = mutationLock
        let searchIndexCache = searchIndexCache
        let searchTask = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let conversationFileURLsById = try Self.conversationFileURLsById(in: directoryURL)
            let keyData = try keyCache.keyData()
            let orderedCandidateIds = candidateIds.sorted { $0.uuidString < $1.uuidString }
            let maximumConcurrentSearches = 4
            var matchingIds: Set<UUID> = []

            for batchStart in stride(from: 0, to: orderedCandidateIds.count, by: maximumConcurrentSearches) {
                try Task.checkCancellation()
                let batchEnd = min(batchStart + maximumConcurrentSearches, orderedCandidateIds.count)
                let batch = orderedCandidateIds[batchStart ..< batchEnd]

                let batchMatches = try await withThrowingTaskGroup(of: (UUID, Bool).self) { group in
                    for conversationId in batch {
                        guard let conversationURL = conversationFileURLsById[conversationId] else { continue }
                        group.addTask {
                            try await Self.fullTextSearchMatches(
                                query: query,
                                conversationId: conversationId,
                                conversationURL: conversationURL,
                                searchIndexDirectoryURL: searchIndexDirectoryURL,
                                stagingDirectoryURL: stagingDirectoryURL,
                                persistBuiltIndex: persistBuiltIndexes,
                                keyData: keyData,
                                mutationLock: mutationLock,
                                searchIndexCache: searchIndexCache
                            )
                        }
                    }

                    var results: [(UUID, Bool)] = []
                    for try await result in group {
                        try Task.checkCancellation()
                        results.append(result)
                    }
                    return results
                }

                for (conversationId, matches) in batchMatches where matches {
                    matchingIds.insert(conversationId)
                }
            }

            return matchingIds
        }

        return try await withTaskCancellationHandler {
            try await searchTask.value
        } onCancel: {
            searchTask.cancel()
        }
    }

    private nonisolated static func fullTextSearchMatches(
        query: String,
        conversationId: UUID,
        conversationURL: URL,
        searchIndexDirectoryURL: URL,
        stagingDirectoryURL: URL,
        persistBuiltIndex: Bool,
        keyData: Data,
        mutationLock: MutationLock,
        searchIndexCache: SearchIndexCache,
        allowRetry: Bool = true
    ) async throws -> (UUID, Bool) {
        try Task.checkCancellation()
        let searchIndexURL = searchIndexFileURL(
            for: conversationId,
            in: searchIndexDirectoryURL
        )

        do {
            if let cached = mutationLock.withLock({ () -> SearchIndexCache.Entry? in
                guard let currentVersion = fileVersion(at: conversationURL),
                      let cached = searchIndexCache.entry(for: conversationId),
                      cached.fileVersion == currentVersion
                else {
                    return nil
                }
                return cached
            }) {
                let matches = fieldsContainQuery(cached.searchableFields, query: query)
                let stillCurrent = mutationLock.withLock {
                    fileVersion(at: conversationURL) == cached.fileVersion
                }
                if !stillCurrent {
                    guard allowRetry else { return (conversationId, false) }
                    return try await fullTextSearchMatches(
                        query: query,
                        conversationId: conversationId,
                        conversationURL: conversationURL,
                        searchIndexDirectoryURL: searchIndexDirectoryURL,
                        stagingDirectoryURL: stagingDirectoryURL,
                        persistBuiltIndex: persistBuiltIndex,
                        keyData: keyData,
                        mutationLock: mutationLock,
                        searchIndexCache: searchIndexCache,
                        allowRetry: false
                    )
                }
                return (conversationId, matches)
            }

            let persistedSourceVersion = mutationLock.withLock {
                fileVersion(at: conversationURL)
            }
            if let persistedSourceVersion,
               FileManager.default.fileExists(atPath: searchIndexURL.path),
               let index = try? loadSearchIndexCancellable(from: searchIndexURL, keyData: keyData),
               index.id == conversationId,
               index.sourceVersion == persistedSourceVersion,
               index.searchableFields.reduce(into: 0, { $0 += $1.utf8.count })
               <= SearchIndexCache.maximumEntryCost
            {
                let persisted = SearchIndexCache.Entry(
                    fileVersion: persistedSourceVersion,
                    searchableFields: index.searchableFields
                )
                let published = try mutationLock.withLock { () -> Bool in
                    try Task.checkCancellation()
                    guard fileVersion(at: conversationURL) == persistedSourceVersion else {
                        return false
                    }
                    searchIndexCache.set(persisted, for: conversationId)
                    return true
                }
                if !published {
                    guard allowRetry else { return (conversationId, false) }
                    return try await fullTextSearchMatches(
                        query: query,
                        conversationId: conversationId,
                        conversationURL: conversationURL,
                        searchIndexDirectoryURL: searchIndexDirectoryURL,
                        stagingDirectoryURL: stagingDirectoryURL,
                        persistBuiltIndex: persistBuiltIndex,
                        keyData: keyData,
                        mutationLock: mutationLock,
                        searchIndexCache: searchIndexCache,
                        allowRetry: false
                    )
                }

                let matches = fieldsContainQuery(persisted.searchableFields, query: query)
                let stillCurrent = mutationLock.withLock {
                    fileVersion(at: conversationURL) == persisted.fileVersion
                }
                if !stillCurrent {
                    guard allowRetry else { return (conversationId, false) }
                    return try await fullTextSearchMatches(
                        query: query,
                        conversationId: conversationId,
                        conversationURL: conversationURL,
                        searchIndexDirectoryURL: searchIndexDirectoryURL,
                        stagingDirectoryURL: stagingDirectoryURL,
                        persistBuiltIndex: persistBuiltIndex,
                        keyData: keyData,
                        mutationLock: mutationLock,
                        searchIndexCache: searchIndexCache,
                        allowRetry: false
                    )
                }
                return (conversationId, matches)
            }

            guard let sourceVersion = fileVersion(at: conversationURL) else {
                return (conversationId, false)
            }
            let conversation = try loadCancellable(from: conversationURL, keyData: keyData)
            let searchableFields = try cacheableSearchFields(from: conversation)
            let matches: Bool = if let searchableFields {
                fieldsContainQuery(searchableFields, query: query)
            } else {
                try conversationMatchesFullText(conversation, query: query)
            }

            let encryptedIndex: Data? = if persistBuiltIndex, let searchableFields {
                try? encryptedData(
                    for: ConversationSearchIndex(
                        id: conversationId,
                        sourceVersion: sourceVersion,
                        searchableFields: searchableFields
                    ),
                    keyData: keyData
                )
            } else {
                nil
            }

            var preparedIndexURL: URL?
            if let encryptedIndex {
                do {
                    try ensureDirectoryExists(stagingDirectoryURL)
                    let temporaryURL = stagingDirectoryURL.appendingPathComponent(
                        ".\(conversationId.uuidString).\(UUID().uuidString).search.tmp"
                    )
                    try encryptedIndex.write(to: temporaryURL, options: .atomic)
                    preparedIndexURL = temporaryURL
                    try Task.checkCancellation()
                } catch is CancellationError {
                    if let preparedIndexURL {
                        try? FileManager.default.removeItem(at: preparedIndexURL)
                    }
                    throw CancellationError()
                } catch {
                    DiagnosticsLogger.log(
                        .encryptedStore,
                        level: .error,
                        message: "Failed to prepare conversation search index",
                        metadata: [
                            "id": conversationId.uuidString,
                            "error": error.localizedDescription
                        ]
                    )
                }
            }
            defer {
                if let preparedIndexURL {
                    try? FileManager.default.removeItem(at: preparedIndexURL)
                }
            }

            let committed = try mutationLock.withLock { () -> Bool in
                try Task.checkCancellation()
                guard fileVersion(at: conversationURL) == sourceVersion else { return false }
                if let searchableFields {
                    searchIndexCache.set(
                        .init(fileVersion: sourceVersion, searchableFields: searchableFields),
                        for: conversationId
                    )
                    if let preparedIndexURL {
                        do {
                            try ensureDirectoryExists(searchIndexDirectoryURL)
                            if FileManager.default.fileExists(atPath: searchIndexURL.path) {
                                _ = try FileManager.default.replaceItemAt(
                                    searchIndexURL,
                                    withItemAt: preparedIndexURL
                                )
                            } else {
                                try FileManager.default.moveItem(
                                    at: preparedIndexURL,
                                    to: searchIndexURL
                                )
                            }
                        } catch {
                            DiagnosticsLogger.log(
                                .encryptedStore,
                                level: .error,
                                message: "Failed to persist conversation search index",
                                metadata: [
                                    "id": conversationId.uuidString,
                                    "error": error.localizedDescription
                                ]
                            )
                        }
                    }
                }
                return true
            }

            if !committed {
                guard allowRetry else { return (conversationId, false) }
                return try await fullTextSearchMatches(
                    query: query,
                    conversationId: conversationId,
                    conversationURL: conversationURL,
                    searchIndexDirectoryURL: searchIndexDirectoryURL,
                    stagingDirectoryURL: stagingDirectoryURL,
                    persistBuiltIndex: persistBuiltIndex,
                    keyData: keyData,
                    mutationLock: mutationLock,
                    searchIndexCache: searchIndexCache,
                    allowRetry: false
                )
            }

            try Task.checkCancellation()
            return (conversationId, matches)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "Failed to search conversation history",
                metadata: [
                    "id": conversationId.uuidString,
                    "error": error.localizedDescription
                ]
            )
            return (conversationId, false)
        }
    }

    private nonisolated static func conversationMatchesFullText(
        _ conversation: Conversation,
        query: String
    ) throws -> Bool {
        try Task.checkCancellation()
        if conversation.title.localizedCaseInsensitiveContains(query) {
            return true
        }
        for message in conversation.messages {
            try Task.checkCancellation()
            if message.content.localizedCaseInsensitiveContains(query) {
                return true
            }
        }
        return false
    }

    private nonisolated static func cacheableSearchFields(
        from conversation: Conversation
    ) throws -> [String]? {
        var utf8Count = conversation.title.utf8.count
        for message in conversation.messages {
            try Task.checkCancellation()
            utf8Count += 1 + message.content.utf8.count
            guard utf8Count <= SearchIndexCache.maximumEntryCost else {
                return nil
            }
        }
        return [conversation.title] + conversation.messages.map(\.content)
    }

    private nonisolated static func fieldsContainQuery(
        _ fields: [String],
        query: String
    ) -> Bool {
        fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    func save(_ conversation: Conversation) async throws {
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL
        let searchIndexDirectoryURL = searchIndexDirectoryURL
        let stagingDirectoryURL = stagingDirectoryURL
        let keyCache = encryptionKeyCache
        let mutationLock = mutationLock
        let sharedMutationState = sharedMutationState
        let searchIndexCache = searchIndexCache
        let operationGenerations = operationGenerations
        let saveGeneration = operationGenerations.currentGeneration(for: conversation.id)

        let saveTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let keyData = try keyCache.keyData()
            let preparedWrite = try Self.prepareWrite(conversation, keyData: keyData)
            try Task.checkCancellation()
            try Self.withStagedWrite(
                preparedWrite,
                stagingDirectory: stagingDirectoryURL
            ) { stagedWrite in
                try mutationLock.withLock {
                    if let unresolvedBackupPaths = sharedMutationState.unresolvedClearBackupPaths {
                        throw EncryptedStoreError.clearRecoveryRequired(paths: unresolvedBackupPaths)
                    }
                    if let scanFailurePaths = sharedMutationState.privacyCleanupMarkerScanFailurePaths {
                        throw EncryptedStoreError.clearRecoveryRequired(paths: scanFailurePaths)
                    }
                    guard operationGenerations.matches(saveGeneration, for: conversation.id) else {
                        DiagnosticsLogger.log(
                            .encryptedStore,
                            level: .info,
                            message: "Skipped save for deleted conversation",
                            metadata: ["id": conversation.id.uuidString]
                        )
                        return
                    }
                    let searchIndexURL = Self.searchIndexFileURL(
                        for: conversation.id,
                        in: searchIndexDirectoryURL
                    )
                    if FileManager.default.fileExists(atPath: searchIndexURL.path) {
                        do {
                            try Data().write(to: searchIndexURL, options: .atomic)
                            try? FileManager.default.removeItem(at: searchIndexURL)
                        } catch {
                            DiagnosticsLogger.log(
                                .encryptedStore,
                                level: .error,
                                message: "Failed to invalidate stale conversation search index",
                                metadata: [
                                    "id": conversation.id.uuidString,
                                    "error": error.localizedDescription
                                ]
                            )
                        }
                    }
                    try Self.commit(
                        stagedWrite,
                        to: directoryURL,
                        metadataDirectory: metadataDirectoryURL
                    )
                    searchIndexCache.remove(conversation.id)
                }
            }
        }

        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await saveTask.value
                try Task.checkCancellation()
            } catch is CancellationError {
                saveTask.cancel()
                _ = try? await saveTask.value
                throw CancellationError()
            }
        } onCancel: {
            saveTask.cancel()
        }
    }

    func delete(_ conversationId: UUID) async throws {
        let directoryURL = directoryURL
        let metadataDirectoryURL = metadataDirectoryURL
        let searchIndexDirectoryURL = searchIndexDirectoryURL
        let mutationLock = mutationLock
        let sharedMutationState = sharedMutationState
        let searchIndexCache = searchIndexCache
        let operationGenerations = operationGenerations
        let deleteGeneration = operationGenerations.currentGeneration(for: conversationId)

        try await Task.detached(priority: .userInitiated) {
            try mutationLock.withLock {
                if let unresolvedBackupPaths = sharedMutationState.unresolvedClearBackupPaths {
                    throw EncryptedStoreError.clearRecoveryRequired(paths: unresolvedBackupPaths)
                }
                if let scanFailurePaths = sharedMutationState.privacyCleanupMarkerScanFailurePaths {
                    throw EncryptedStoreError.clearRecoveryRequired(paths: scanFailurePaths)
                }
                guard operationGenerations.matches(deleteGeneration, for: conversationId) else {
                    DiagnosticsLogger.log(
                        .encryptedStore,
                        level: .info,
                        message: "Skipped stale conversation delete",
                        metadata: ["id": conversationId.uuidString]
                    )
                    return
                }
                // The index contains full message text, so remove it before the authoritative record.
                let searchIndexURL = Self.searchIndexFileURL(
                    for: conversationId,
                    in: searchIndexDirectoryURL
                )
                if FileManager.default.fileExists(atPath: searchIndexURL.path) {
                    try FileManager.default.removeItem(at: searchIndexURL)
                }

                for fileURL in try Self.conversationFileURLs(matching: conversationId, in: directoryURL) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                operationGenerations.advanceGeneration(for: conversationId)
                searchIndexCache.remove(conversationId)

                for metadataURL in try Self.metadataFileURLs(matching: conversationId, in: metadataDirectoryURL) {
                    do {
                        try FileManager.default.removeItem(at: metadataURL)
                    } catch {
                        DiagnosticsLogger.log(
                            .encryptedStore,
                            level: .error,
                            message: "Failed to remove conversation metadata after deletion",
                            metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
                        )
                    }
                }
            }
        }.value
    }

    // Deprecated: Use save(_ conversation:) instead
    func save(_ conversations: [Conversation]) async throws {
        for conversation in conversations {
            try await save(conversation)
        }
    }

    private nonisolated static func symbolicLinkPath(in urls: [URL]) -> String? {
        for url in urls {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return url.path
            }
        }
        return nil
    }

    func clear(attachmentCleanupSnapshot: AttachmentCleanupSnapshot? = nil) throws {
        let parentDirectory = directoryURL.deletingLastPathComponent()
        let transactionId = UUID().uuidString
        let conversationBackupPrefix = Self.scopedClearArtifactPrefix(
            Self.conversationClearBackupPrefix,
            directoryURL: directoryURL
        )
        let legacyBackupPrefix = Self.scopedClearArtifactPrefix(
            Self.legacyClearBackupPrefix,
            directoryURL: directoryURL
        )
        let commitMarkerPrefix = Self.scopedClearArtifactPrefix(
            Self.clearCommitMarkerPrefix,
            directoryURL: directoryURL
        )
        let backupDirectory = parentDirectory.appendingPathComponent(
            "\(conversationBackupPrefix)\(transactionId)",
            isDirectory: true
        )
        let legacyBackupURL = legacyFileURL.deletingLastPathComponent().appendingPathComponent(
            "\(legacyBackupPrefix)\(transactionId)"
        )
        let commitMarkerURL = parentDirectory.appendingPathComponent(
            "\(commitMarkerPrefix)\(transactionId)"
        )
        let privacyCleanupMarkerURL = parentDirectory.appendingPathComponent(
            "\(scopedPrivacyCleanupMarkerPrefix)\(transactionId)"
        )
        var movedDirectory = false
        var movedLegacyFile = false

        try mutationLock.withLock {
            if let unresolvedBackupPaths = sharedMutationState.unresolvedClearBackupPaths {
                throw EncryptedStoreError.clearRecoveryRequired(paths: unresolvedBackupPaths)
            }
            if let scanFailurePaths = sharedMutationState.privacyCleanupMarkerScanFailurePaths {
                throw EncryptedStoreError.clearRecoveryRequired(paths: scanFailurePaths)
            }
            if let pendingCleanupPaths = sharedMutationState.pendingCommittedCleanupPaths {
                throw EncryptedStoreError.clearCleanupPending(paths: pendingCleanupPaths)
            }
            if let symbolicLinkPath = Self.symbolicLinkPath(in: [
                directoryURL,
                metadataDirectoryURL,
                searchIndexDirectoryURL,
                legacyFileURL,
            ]) {
                throw EncryptedStoreError.unsupportedClearSymbolicLink(path: symbolicLinkPath)
            }
            do {
                if FileManager.default.fileExists(atPath: directoryURL.path) {
                    try moveOperation(directoryURL, backupDirectory)
                    movedDirectory = true
                }
                if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                    try moveOperation(legacyFileURL, legacyBackupURL)
                    movedLegacyFile = true
                }

                try Self.ensureDirectoryExists(directoryURL)
                try Self.ensureDirectoryExists(metadataDirectoryURL)
                try Self.ensureDirectoryExists(searchIndexDirectoryURL)
                let privacyMarkerState = PrivacyCleanupMarkerState(
                    attachmentFileNames: attachmentCleanupSnapshot?.fileNames.sorted()
                )
                let privacyMarkerData = try JSONEncoder().encode(privacyMarkerState)
                try privacyMarkerData.write(to: privacyCleanupMarkerURL, options: .atomic)
                try Data().write(to: commitMarkerURL, options: .atomic)
                operationGenerations.advanceAllGenerations()
                searchIndexCache.removeAll()
            } catch {
                do {
                    if movedDirectory,
                       FileManager.default.fileExists(atPath: directoryURL.path)
                    {
                        try FileManager.default.removeItem(at: directoryURL)
                    }
                    if movedDirectory,
                       FileManager.default.fileExists(atPath: backupDirectory.path)
                    {
                        try moveOperation(backupDirectory, directoryURL)
                    }
                    if movedLegacyFile,
                       FileManager.default.fileExists(atPath: legacyBackupURL.path)
                    {
                        try moveOperation(legacyBackupURL, legacyFileURL)
                    }
                    try? FileManager.default.removeItem(at: privacyCleanupMarkerURL)
                    try? FileManager.default.removeItem(at: commitMarkerURL)
                } catch let rollbackError {
                    let unresolvedBackupPaths = [backupDirectory, legacyBackupURL]
                        .filter { FileManager.default.fileExists(atPath: $0.path) }
                        .map(\.path)
                    sharedMutationState.unresolvedClearBackupPaths = unresolvedBackupPaths.isEmpty
                        ? [backupDirectory.path, legacyBackupURL.path]
                        : unresolvedBackupPaths
                    DiagnosticsLogger.log(
                        .encryptedStore,
                        level: .error,
                        message: "Failed to roll back conversation clear transaction",
                        metadata: [
                            "error": rollbackError.localizedDescription,
                            "backup": backupDirectory.path
                        ]
                    )
                    throw EncryptedStoreError.clearRollbackFailed(
                        paths: sharedMutationState.unresolvedClearBackupPaths ?? []
                    )
                }
                throw error
            }
        }

        let committedBackups = [
            movedLegacyFile ? legacyBackupURL : nil,
            movedDirectory ? backupDirectory : nil
        ].compactMap(\.self)
        let failedBackupPaths = mutationLock.withLock { () -> [String] in
            var failedBackupPaths: [String] = []
            for backupURL in committedBackups {
                guard FileManager.default.fileExists(atPath: backupURL.path) else { continue }
                do {
                    try backupRemovalOperation(backupURL)
                } catch {
                    failedBackupPaths.append(backupURL.path)
                    DiagnosticsLogger.log(
                        .encryptedStore,
                        level: .error,
                        message: "Failed to remove committed conversation clear backup",
                        metadata: [
                            "error": error.localizedDescription,
                            "backup": backupURL.path
                        ]
                    )
                }
            }
            if failedBackupPaths.isEmpty {
                if let existingPaths = sharedMutationState.pendingCommittedCleanupPaths {
                    let cleanedPaths = Set(committedBackups.map(\.path))
                    let remainingPaths = existingPaths.filter { !cleanedPaths.contains($0) }
                    sharedMutationState.pendingCommittedCleanupPaths = remainingPaths.isEmpty
                        ? nil
                        : remainingPaths
                }
            } else {
                let existingPaths = sharedMutationState.pendingCommittedCleanupPaths ?? []
                sharedMutationState.pendingCommittedCleanupPaths = Array(Set(existingPaths + failedBackupPaths))
            }
            return failedBackupPaths
        }
        if !failedBackupPaths.isEmpty {
            throw EncryptedStoreError.clearBackupCleanupFailed(paths: failedBackupPaths)
        }
        Self.stagingCleanupRegistry.removeAbandonedDirectories(
            in: parentDirectory,
            onlyOncePerProcess: false
        )
        if legacyFileURL.deletingLastPathComponent() != parentDirectory {
            Self.stagingCleanupRegistry.removeAbandonedDirectories(
                in: legacyFileURL.deletingLastPathComponent(),
                onlyOncePerProcess: false
            )
        }
        log("Cleared encrypted conversation store")
    }

    // MARK: - Helpers

    private nonisolated static func loadCanonicalConversations(
        in directory: URL,
        keyData: Data,
        mutationLock: MutationLock,
        operationGenerations: OperationGenerationRegistry
    ) async throws -> [Conversation] {
        let fileURLsById = try conversationFileURLsById(in: directory)
        let snapshots = fileURLsById.compactMap { id, url -> (
            UUID,
            URL,
            FileVersion,
            OperationGenerationRegistry.Generation
        )? in
            guard let version = fileVersion(at: url) else { return nil }
            return (id, url, version, operationGenerations.currentGeneration(for: id))
        }

        return try await withThrowingTaskGroup(of: (
            UUID,
            URL,
            FileVersion,
            OperationGenerationRegistry.Generation,
            Conversation?
        ).self) { group in
            for (id, url, version, generation) in snapshots {
                group.addTask {
                    do {
                        let conversation = try loadCancellable(from: url, keyData: keyData)
                        return (id, url, version, generation, conversation)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        DiagnosticsLogger.log(
                            .encryptedStore,
                            level: .error,
                            message: "Failed to load canonical migrated conversation",
                            metadata: [
                                "id": id.uuidString,
                                "error": error.localizedDescription
                            ]
                        )
                        return (id, url, version, generation, nil)
                    }
                }
            }

            var conversations: [Conversation] = []
            conversations.reserveCapacity(snapshots.count)
            for try await (id, url, version, generation, conversation) in group {
                try Task.checkCancellation()
                guard let conversation else { continue }
                let isCurrent = mutationLock.withLock {
                    operationGenerations.matches(generation, for: id)
                        && fileVersion(at: url) == version
                }
                if isCurrent {
                    conversations.append(conversation)
                }
            }
            return conversations
        }
    }

    private nonisolated static func loadLegacyFile(at url: URL, keyData: Data)
        throws -> [Conversation]
    {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode([Conversation].self, from: plaintext)
    }

    private nonisolated static func deduplicatedLegacyConversations(
        _ conversations: [Conversation]
    ) -> [Conversation] {
        var result: [Conversation] = []
        result.reserveCapacity(conversations.count)
        var indexById: [UUID: Int] = [:]
        indexById.reserveCapacity(conversations.count)

        for conversation in conversations {
            if let index = indexById[conversation.id] {
                result[index] = conversation
            } else {
                indexById[conversation.id] = result.count
                result.append(conversation)
            }
        }

        return result
    }

    private nonisolated static func load(from url: URL, keyData: Data) throws -> Conversation {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Conversation.self, from: plaintext)
    }

    private nonisolated static func loadCancellable(from url: URL, keyData: Data) throws -> Conversation {
        let encryptedData = try readDataCancellable(from: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        try Task.checkCancellation()
        let conversation = try JSONDecoder().decode(Conversation.self, from: plaintext)
        try Task.checkCancellation()
        return conversation
    }

    private nonisolated static func readDataCancellable(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        var data = Data()
        if let fileSize {
            data.reserveCapacity(fileSize)
        }

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }

        try Task.checkCancellation()
        return data
    }

    private nonisolated static func loadMetadata(from url: URL, keyData: Data) throws -> ConversationMetadata {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(ConversationMetadata.self, from: plaintext)
    }

    private nonisolated static func prepareWrite(
        _ conversation: Conversation,
        keyData: Data
    ) throws -> PreparedConversationWrite {
        let encryptedConversation = try encryptedData(for: conversation, keyData: keyData)
        let encryptedMetadata: Data?
        do {
            encryptedMetadata = try encryptedData(
                for: ConversationMetadata(conversation: conversation),
                keyData: keyData
            )
        } catch {
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "Failed to prepare conversation metadata sidecar",
                metadata: ["id": conversation.id.uuidString, "error": error.localizedDescription]
            )
            encryptedMetadata = nil
        }
        return PreparedConversationWrite(
            id: conversation.id,
            encryptedConversation: encryptedConversation,
            encryptedMetadata: encryptedMetadata
        )
    }

    private nonisolated static func withStagedWrite<T>(
        _ preparedWrite: PreparedConversationWrite,
        stagingDirectory: URL,
        operation: (StagedConversationWrite) throws -> T
    ) throws -> T {
        let stagedWrite = try stage(
            preparedWrite,
            in: stagingDirectory
        )
        defer { cleanup(stagedWrite) }
        try Task.checkCancellation()
        return try operation(stagedWrite)
    }

    private nonisolated static func migrateLegacyConversation(
        _ conversation: Conversation,
        keyData: Data,
        directory: URL,
        metadataDirectory: URL,
        stagingDirectory: URL,
        mutationLock: MutationLock,
        operationGenerations: OperationGenerationRegistry,
        expectedGlobalGeneration: UInt64
    ) throws -> Bool? {
        let fileURL = directory.appendingPathComponent("\(conversation.id.uuidString).enc")
        let expectedExistingVersion = fileVersion(at: fileURL)
        if expectedExistingVersion != nil {
            do {
                let canonicalConversation = try loadCancellable(from: fileURL, keyData: keyData)
                if canonicalConversation.id == conversation.id,
                   canonicalConversation.updatedAt >= conversation.updatedAt
                {
                    return mutationLock.withLock {
                        guard operationGenerations.matchesGlobalGeneration(expectedGlobalGeneration) else {
                            return nil
                        }
                        let generation = operationGenerations.currentGeneration(for: conversation.id)
                        guard generation.conversation == 0 else { return false }
                        guard fileVersion(at: fileURL) == expectedExistingVersion else { return nil }
                        return false
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Replace an unreadable canonical file with the valid legacy record.
            }
        }

        let preparedWrite = try prepareWrite(conversation, keyData: keyData)
        return try withStagedWrite(
            preparedWrite,
            stagingDirectory: stagingDirectory
        ) { stagedWrite -> Bool? in
            try mutationLock.withLock { () -> Bool? in
                guard operationGenerations.matchesGlobalGeneration(expectedGlobalGeneration) else {
                    return nil
                }
                let generation = operationGenerations.currentGeneration(for: conversation.id)
                guard generation.conversation == 0 else { return false }
                guard fileVersion(at: fileURL) == expectedExistingVersion else { return nil }
                try commit(
                    stagedWrite,
                    to: directory,
                    metadataDirectory: metadataDirectory
                )
                return true
            }
        }
    }

    private nonisolated static func stage(
        _ preparedWrite: PreparedConversationWrite,
        in stagingDirectory: URL
    ) throws -> StagedConversationWrite {
        try ensureDirectoryExists(stagingDirectory)
        let conversationTemporaryURL = stagingDirectory.appendingPathComponent(
            ".\(preparedWrite.id.uuidString).\(UUID().uuidString).conversation.tmp"
        )
        do {
            try preparedWrite.encryptedConversation.write(
                to: conversationTemporaryURL,
                options: .atomic
            )
        } catch {
            try? FileManager.default.removeItem(at: conversationTemporaryURL)
            throw error
        }

        var metadataTemporaryURL: URL?
        if let encryptedMetadata = preparedWrite.encryptedMetadata {
            let temporaryURL = stagingDirectory.appendingPathComponent(
                ".\(preparedWrite.id.uuidString).\(UUID().uuidString).metadata.tmp"
            )
            do {
                try encryptedMetadata.write(to: temporaryURL, options: .atomic)
                metadataTemporaryURL = temporaryURL
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .error,
                    message: "Failed to stage conversation metadata sidecar",
                    metadata: ["id": preparedWrite.id.uuidString, "error": error.localizedDescription]
                )
            }
        }

        return StagedConversationWrite(
            id: preparedWrite.id,
            conversationTemporaryURL: conversationTemporaryURL,
            metadataTemporaryURL: metadataTemporaryURL
        )
    }

    private nonisolated static func commit(
        _ stagedWrite: StagedConversationWrite,
        to directory: URL,
        metadataDirectory: URL
    ) throws {
        try ensureDirectoryExists(directory)
        let fileURL = directory.appendingPathComponent("\(stagedWrite.id.uuidString).enc")
        try installStagedFile(stagedWrite.conversationTemporaryURL, at: fileURL)

        guard let metadataTemporaryURL = stagedWrite.metadataTemporaryURL else { return }
        do {
            try ensureDirectoryExists(metadataDirectory)
            let metadataURL = metadataFileURL(for: stagedWrite.id, in: metadataDirectory)
            try installStagedFile(metadataTemporaryURL, at: metadataURL)
        } catch {
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "Failed to save conversation metadata sidecar",
                metadata: ["id": stagedWrite.id.uuidString, "error": error.localizedDescription]
            )
        }
    }

    private nonisolated static func installStagedFile(_ stagedURL: URL, at destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    private nonisolated static func cleanup(_ stagedWrite: StagedConversationWrite) {
        try? FileManager.default.removeItem(at: stagedWrite.conversationTemporaryURL)
        if let metadataTemporaryURL = stagedWrite.metadataTemporaryURL {
            try? FileManager.default.removeItem(at: metadataTemporaryURL)
        }
    }

    private nonisolated static func encryptedData(
        for value: some Encodable,
        keyData: Data
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        let key = SymmetricKey(data: keyData)
        let sealed = try AES.GCM.seal(encoded, using: key)
        guard let combined = sealed.combined else {
            throw KeychainStorageError.unexpectedStatus(errSecParam)
        }
        return combined
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

    private nonisolated static func sidecarIsOlderThanConversation(
        sidecarURL: URL,
        conversationURL: URL
    ) -> Bool {
        do {
            let metadataValues = try sidecarURL.resourceValues(forKeys: [.contentModificationDateKey])
            let conversationValues = try conversationURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let metadataDate = metadataValues.contentModificationDate,
                  let conversationDate = conversationValues.contentModificationDate
            else {
                return true
            }
            return conversationDate > metadataDate
        } catch {
            return true
        }
    }

    private nonisolated static func fileVersion(at url: URL) -> FileVersion? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey
            ])
            return FileVersion(
                modificationDate: values.contentModificationDate,
                fileSize: values.fileSize
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func loadStableFullMetadata(
        conversationURL: URL,
        keyData: Data
    ) throws -> (metadata: ConversationMetadata, sourceVersion: FileVersion)? {
        for _ in 0 ..< 2 {
            try Task.checkCancellation()
            guard let sourceVersion = fileVersion(at: conversationURL) else { return nil }
            let conversation = try loadCancellable(from: conversationURL, keyData: keyData)
            guard fileVersion(at: conversationURL) == sourceVersion else { continue }
            return (ConversationMetadata(conversation: conversation), sourceVersion)
        }
        return nil
    }

    private nonisolated static func commitMetadataCandidate(
        _ metadata: ConversationMetadata,
        sourceVersion: FileVersion,
        shouldPersistSidecar: Bool,
        conversationId: UUID,
        conversationURL: URL,
        metadataDirectory: URL,
        stagingDirectory: URL,
        keyData: Data,
        mutationLock: MutationLock,
        operationGenerations: OperationGenerationRegistry,
        expectedGeneration: OperationGenerationRegistry.Generation,
        expectedGlobalGeneration: UInt64
    ) throws -> Bool {
        var stagedMetadataURL: URL?
        if shouldPersistSidecar {
            do {
                let encryptedMetadata = try encryptedData(for: metadata, keyData: keyData)
                try ensureDirectoryExists(stagingDirectory)
                let temporaryURL = stagingDirectory.appendingPathComponent(
                    ".\(conversationId.uuidString).\(UUID().uuidString).metadata.tmp"
                )
                try encryptedMetadata.write(to: temporaryURL, options: .atomic)
                stagedMetadataURL = temporaryURL
                try Task.checkCancellation()
            } catch is CancellationError {
                if let stagedMetadataURL {
                    try? FileManager.default.removeItem(at: stagedMetadataURL)
                }
                throw CancellationError()
            } catch {
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .error,
                    message: "Failed to prepare conversation metadata sidecar",
                    metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
                )
            }
        }
        defer {
            if let stagedMetadataURL {
                try? FileManager.default.removeItem(at: stagedMetadataURL)
            }
        }

        return mutationLock.withLock {
            guard operationGenerations.matchesGlobalGeneration(expectedGlobalGeneration),
                  operationGenerations.matches(expectedGeneration, for: conversationId),
                  fileVersion(at: conversationURL) == sourceVersion
            else {
                return false
            }

            if let stagedMetadataURL {
                do {
                    try ensureDirectoryExists(metadataDirectory)
                    let metadataURL = metadataFileURL(for: conversationId, in: metadataDirectory)
                    try installStagedFile(stagedMetadataURL, at: metadataURL)
                } catch {
                    DiagnosticsLogger.log(
                        .encryptedStore,
                        level: .error,
                        message: "Failed to save conversation metadata sidecar",
                        metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
                    )
                }
            }
            return true
        }
    }

    private nonisolated static func loadFullConversationsAsMetadata(
        conversationFileURLsById: [UUID: URL],
        keyData: Data
    ) async -> [UUID: ConversationMetadata] {
        await withTaskGroup(of: (UUID, ConversationMetadata?).self) { group in
            for (id, url) in conversationFileURLsById {
                group.addTask {
                    do {
                        let conversation = try Self.load(from: url, keyData: keyData)
                        let metadata = ConversationMetadata(conversation: conversation)
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
        return conversationFileURLsById(from: fileURLs)
    }

    nonisolated static func conversationFileURLsById(from fileURLs: [URL]) -> [UUID: URL] {
        fileURLs.reduce(into: [UUID: URL]()) { result, url in
            guard url.pathExtension == "enc",
                  url.deletingPathExtension().lastPathComponent.contains(".") == false,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else {
                return
            }
            insertStorageFileURL(
                url,
                id: id,
                canonicalFileName: "\(id.uuidString).enc",
                into: &result
            )
        }
    }

    nonisolated static func conversationFileURLs(
        matching id: UUID,
        from fileURLs: [URL]
    ) -> [URL] {
        fileURLs.filter { url in
            guard url.pathExtension == "enc",
                  url.deletingPathExtension().lastPathComponent.contains(".") == false,
                  let parsedID = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else {
                return false
            }
            return parsedID == id
        }
    }

    private nonisolated static func conversationFileURLs(
        matching id: UUID,
        in directory: URL
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return conversationFileURLs(matching: id, from: fileURLs)
    }

    private nonisolated static func metadataFileURLsById(in metadataDirectory: URL) throws -> [UUID: URL] {
        guard FileManager.default.fileExists(atPath: metadataDirectory.path) else {
            return [:]
        }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil
        )
        return metadataFileURLsById(from: fileURLs)
    }

    nonisolated static func metadataFileURLsById(from fileURLs: [URL]) -> [UUID: URL] {
        fileURLs.reduce(into: [UUID: URL]()) { result, url in
            guard let id = metadataId(from: url) else { return }
            insertStorageFileURL(
                url,
                id: id,
                canonicalFileName: "\(id.uuidString).metadata.enc",
                into: &result
            )
        }
    }

    nonisolated static func metadataFileURLs(
        matching id: UUID,
        from fileURLs: [URL]
    ) -> [URL] {
        fileURLs.filter { url in
            metadataId(from: url) == id
        }
    }

    private nonisolated static func metadataFileURLs(
        matching id: UUID,
        in directory: URL
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let fileURLs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return metadataFileURLs(matching: id, from: fileURLs)
    }

    private nonisolated static func insertStorageFileURL(
        _ candidate: URL,
        id: UUID,
        canonicalFileName: String,
        into result: inout [UUID: URL]
    ) {
        guard let existing = result[id] else {
            result[id] = candidate
            return
        }

        let preferred: URL = if candidate.lastPathComponent == canonicalFileName {
            candidate
        } else if existing.lastPathComponent == canonicalFileName {
            existing
        } else {
            candidate.lastPathComponent < existing.lastPathComponent
                ? candidate
                : existing
        }
        let discarded = preferred == candidate ? existing : candidate
        result[id] = preferred
        DiagnosticsLogger.log(
            .encryptedStore,
            level: .error,
            message: "Duplicate encrypted storage filename for conversation ID",
            metadata: [
                "id": id.uuidString,
                "kept": preferred.lastPathComponent,
                "discarded": discarded.lastPathComponent
            ]
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

    private nonisolated static func loadSearchIndexCancellable(
        from url: URL,
        keyData: Data
    ) throws -> ConversationSearchIndex {
        let encryptedData = try readDataCancellable(from: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        try Task.checkCancellation()
        let index = try JSONDecoder().decode(ConversationSearchIndex.self, from: plaintext)
        try Task.checkCancellation()
        return index
    }

    private nonisolated static func removeOrphanedSearchIndexes(
        in searchIndexDirectory: URL,
        validConversationIds: Set<UUID>
    ) {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: searchIndexDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in fileURLs {
            if url.lastPathComponent.hasSuffix(".search.tmp") {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            let suffix = ".search.enc"
            let fileName = url.lastPathComponent
            guard fileName.hasSuffix(suffix),
                  let conversationId = UUID(uuidString: String(fileName.dropLast(suffix.count))),
                  !validConversationIds.contains(conversationId)
            else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private nonisolated static func prunePersistedSearchIndexes(
        in searchIndexDirectory: URL,
        keeping retainedConversationIds: Set<UUID>,
        searchIndexCache: SearchIndexCache
    ) {
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: searchIndexDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in fileURLs {
            let suffix = ".search.enc"
            let fileName = url.lastPathComponent
            guard fileName.hasSuffix(suffix),
                  let conversationId = UUID(uuidString: String(fileName.dropLast(suffix.count))),
                  !retainedConversationIds.contains(conversationId)
            else {
                continue
            }
            try? FileManager.default.removeItem(at: url)
            searchIndexCache.remove(conversationId)
        }
    }

    private nonisolated static func searchIndexFileURL(
        for conversationId: UUID,
        in searchIndexDirectory: URL
    ) -> URL {
        searchIndexDirectory.appendingPathComponent("\(conversationId.uuidString).search.enc")
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

    func searchIndexFileURL(for conversationId: UUID) -> URL {
        Self.searchIndexFileURL(for: conversationId, in: searchIndexDirectoryURL)
    }
}
