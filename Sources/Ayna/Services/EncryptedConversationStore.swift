import CryptoKit
import Foundation
import os.log

enum EncryptedStoreError: LocalizedError {
    case keyLost
    case clearBackupCleanupFailed(paths: [String])
    case clearCleanupPending(paths: [String])
    case clearRollbackFailed(paths: [String])
    case clearRecoveryRequired(paths: [String])
    case unsupportedClearSymbolicLink(path: String)
    case unreadableConversationFiles(count: Int)

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
        case let .unreadableConversationFiles(count):
            "Failed to load \(count) encrypted conversation file(s)."
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
        case .keyLost, .clearBackupCleanupFailed, .clearCleanupPending,
             .unsupportedClearSymbolicLink, .unreadableConversationFiles:
            false
        }
    }
}

struct PrivacyCleanupMarkerSnapshot: Sendable {
    let markerFileNames: Set<String>

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

struct PrivacyCleanupMarkerState: Codable {
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

    let directoryURL: URL
    let metadataDirectoryURL: URL
    let searchIndexDirectoryURL: URL
    let stagingDirectoryURL: URL
    let legacyFileURL: URL
    let keyIdentifier: String
    let keychain: KeychainStoring
    let saveCommitOperation: @Sendable (UUID) async throws -> Void
    let metadataRemovalOperation: @Sendable (URL) throws -> Void
    let backupRemovalOperation: @Sendable (URL) throws -> Void
    let clearArtifactDirectoryContentsOperation: @Sendable (URL) throws -> [URL]
    let moveOperation: @Sendable (URL, URL) throws -> Void
    let encryptionKeyCache: EncryptionKeyCache
    let sharedMutationState: SharedMutationState
    let mutationLock: MutationLock
    let searchIndexCache = SearchIndexCache()
    let operationGenerations: OperationGenerationRegistry

    final class EncryptionKeyCache: @unchecked Sendable {
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

    struct FileVersion: Codable, Equatable, Sendable {
        let modificationDate: Date?
        let fileSize: Int?
    }

    struct ConversationSearchIndex: Codable, Sendable {
        let id: UUID
        let sourceVersion: FileVersion
        let searchableFields: [String]
    }

    struct PreparedConversationWrite: Sendable {
        let id: UUID
        let encryptedConversation: Data
        let encryptedMetadata: Data?
    }

    struct StagedConversationWrite: Sendable {
        let id: UUID
        let conversationTemporaryURL: URL
        let metadataTemporaryURL: URL?
    }

    final class MutationLock: @unchecked Sendable {
        private let lock = NSLock()

        func withLock<T>(_ operation: () throws -> T) rethrows -> T {
            lock.lock()
            defer { lock.unlock() }
            return try operation()
        }
    }

    final class SearchIndexCache: @unchecked Sendable {
        static let maximumEntryCost = 4 * 1024 * 1024
        static let maximumTotalCost = 32 * 1024 * 1024

        // swiftlint:disable:next nesting
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

    final class OperationGenerationRegistry: @unchecked Sendable {
        // swiftlint:disable:next nesting
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

    final class SharedMutationState: @unchecked Sendable {
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

    final class StagingCleanupRegistry: @unchecked Sendable {
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

    static let conversationClearBackupPrefix = ".AynaConversationClearBackup-"
    static let legacyClearBackupPrefix = ".AynaLegacyClearBackup-"
    static let clearCommitMarkerPrefix = ".AynaConversationClearCommitted-"
    static let privacyCleanupMarkerPrefix = ".AynaConversationPrivacyCleanupPending-"
    private static let mutationStateRegistry = MutationStateRegistry()
    static let stagingCleanupRegistry = StagingCleanupRegistry()

    init(
        directoryURL: URL? = nil,
        legacyFileURL: URL? = nil,
        keyIdentifier: String = "conversation_encryption_key",
        keychain: KeychainStoring = KeychainStorage.standard,
        saveCommitOperation: @escaping @Sendable (UUID) async throws -> Void = { _ in },
        metadataRemovalOperation: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.removeItem(at: $0)
        },
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
        self.saveCommitOperation = saveCommitOperation
        self.metadataRemovalOperation = metadataRemovalOperation
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
            runStartupClearRecovery(
                mutationState: mutationState,
                stagingParentDirectory: stagingParentDirectory,
                legacyParentDirectory: legacyParentDirectory
            )
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

    func log(
        _ message: String,
        level: OSLogType = .default,
        metadata: [String: String] = [:]
    ) {
        DiagnosticsLogger.log(.encryptedStore, level: level, message: message, metadata: metadata)
    }

    func ensureClearRecoveryResolved() throws {
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
