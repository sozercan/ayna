import CryptoKit
import Foundation
import os.log

extension EncryptedConversationStore {
    private struct ClearTransactionPaths {
        let parentDirectory: URL
        let backupDirectory: URL
        let legacyBackupURL: URL
        let commitMarkerURL: URL
        let privacyCleanupMarkerURL: URL
    }

    nonisolated static func clearArtifactIdentifier(for directoryURL: URL) -> String {
        let canonicalPath = directoryURL.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(canonicalPath.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func scopedClearArtifactPrefix(
        _ basePrefix: String,
        directoryURL: URL
    ) -> String {
        "\(basePrefix)\(clearArtifactIdentifier(for: directoryURL))-"
    }

    func runStartupClearRecovery(
        mutationState: SharedMutationState,
        stagingParentDirectory: URL,
        legacyParentDirectory: URL
    ) {
        do {
            let failedCommittedCleanupPaths = try Self.removeCommittedClearBackups(
                directoryURL: directoryURL,
                conversationParentDirectory: stagingParentDirectory,
                legacyParentDirectory: legacyParentDirectory,
                directoryContentsOperation: clearArtifactDirectoryContentsOperation,
                removeOperation: backupRemovalOperation
            )
            mutationState.pendingCommittedCleanupPaths = failedCommittedCleanupPaths.isEmpty
                ? nil
                : failedCommittedCleanupPaths
            let unresolvedBackupPaths = try Self.recoverUncommittedClearBackup(
                directoryURL: directoryURL,
                legacyFileURL: legacyFileURL,
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
        try? Self.ensureDirectoryExists(directoryURL)
        try? Self.ensureDirectoryExists(metadataDirectoryURL)
        try? Self.ensureDirectoryExists(searchIndexDirectoryURL)
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
                legacyParentDirectory.appendingPathComponent("\(legacyBackupPrefix)\(transactionId)"),
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
                            "backup": backupURL.path,
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
            recoverConversationBackup(
                rollbackBackup,
                directoryURL: directoryURL,
                legacyFileURL: legacyFileURL,
                conversationBackupPrefix: conversationBackupPrefix,
                legacyBackupPrefix: legacyBackupPrefix,
                legacyRollbackBackups: legacyRollbackBackups,
                recoveredTransactionIds: &recoveredTransactionIds
            )
        }

        if recoveredTransactionIds.isEmpty,
           !FileManager.default.fileExists(atPath: legacyFileURL.path),
           let standaloneLegacyBackup = legacyRollbackBackups.first
        {
            recoverStandaloneLegacyBackup(
                standaloneLegacyBackup,
                legacyFileURL: legacyFileURL,
                legacyBackupPrefix: legacyBackupPrefix,
                recoveredTransactionIds: &recoveredTransactionIds
            )
        }

        return (rollbackBackups + legacyRollbackBackups)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)
    }

    private nonisolated static func recoverConversationBackup(
        _ rollbackBackup: URL,
        directoryURL: URL,
        legacyFileURL: URL,
        conversationBackupPrefix: String,
        legacyBackupPrefix: String,
        legacyRollbackBackups: [URL],
        recoveredTransactionIds: inout Set<String>
    ) {
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
                    "backup": rollbackBackup.path,
                ]
            )
        }
    }

    private nonisolated static func recoverStandaloneLegacyBackup(
        _ standaloneLegacyBackup: URL,
        legacyFileURL: URL,
        legacyBackupPrefix: String,
        recoveredTransactionIds: inout Set<String>
    ) {
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
                    "backup": standaloneLegacyBackup.path,
                ]
            )
        }
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
                } catch let error as CocoaError where error.code == .fileNoSuchFile {}
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
                    legacyBackupURL.path,
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

    private nonisolated static func symbolicLinkPath(in urls: [URL]) -> String? {
        for url in urls where (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            return url.path
        }
        return nil
    }

    func clear(attachmentCleanupSnapshot: AttachmentCleanupSnapshot? = nil) throws {
        let paths = makeClearTransactionPaths()
        var movedDirectory = false
        var movedLegacyFile = false

        try mutationLock.withLock {
            try validateClearPreconditions()
            do {
                try commitClearTransaction(
                    paths: paths,
                    attachmentCleanupSnapshot: attachmentCleanupSnapshot,
                    movedDirectory: &movedDirectory,
                    movedLegacyFile: &movedLegacyFile
                )
            } catch {
                try rollbackClearTransaction(
                    paths: paths,
                    movedDirectory: movedDirectory,
                    movedLegacyFile: movedLegacyFile
                )
                throw error
            }
        }

        let committedBackups = [
            movedLegacyFile ? paths.legacyBackupURL : nil,
            movedDirectory ? paths.backupDirectory : nil,
        ].compactMap(\.self)
        try cleanupCommittedClearBackups(committedBackups, parentDirectory: paths.parentDirectory)
        log("Cleared encrypted conversation store")
    }

    private func makeClearTransactionPaths() -> ClearTransactionPaths {
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
        return ClearTransactionPaths(
            parentDirectory: parentDirectory,
            backupDirectory: parentDirectory.appendingPathComponent(
                "\(conversationBackupPrefix)\(transactionId)",
                isDirectory: true
            ),
            legacyBackupURL: legacyFileURL.deletingLastPathComponent().appendingPathComponent(
                "\(legacyBackupPrefix)\(transactionId)"
            ),
            commitMarkerURL: parentDirectory.appendingPathComponent(
                "\(commitMarkerPrefix)\(transactionId)"
            ),
            privacyCleanupMarkerURL: parentDirectory.appendingPathComponent(
                "\(scopedPrivacyCleanupMarkerPrefix)\(transactionId)"
            )
        )
    }

    private func validateClearPreconditions() throws {
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
    }

    private func commitClearTransaction(
        paths: ClearTransactionPaths,
        attachmentCleanupSnapshot: AttachmentCleanupSnapshot?,
        movedDirectory: inout Bool,
        movedLegacyFile: inout Bool
    ) throws {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try moveOperation(directoryURL, paths.backupDirectory)
            movedDirectory = true
        }
        if FileManager.default.fileExists(atPath: legacyFileURL.path) {
            try moveOperation(legacyFileURL, paths.legacyBackupURL)
            movedLegacyFile = true
        }

        try Self.ensureDirectoryExists(directoryURL)
        try Self.ensureDirectoryExists(metadataDirectoryURL)
        try Self.ensureDirectoryExists(searchIndexDirectoryURL)
        let privacyMarkerState = PrivacyCleanupMarkerState(
            attachmentFileNames: attachmentCleanupSnapshot?.fileNames.sorted()
        )
        let privacyMarkerData = try JSONEncoder().encode(privacyMarkerState)
        try privacyMarkerData.write(to: paths.privacyCleanupMarkerURL, options: .atomic)
        try Data().write(to: paths.commitMarkerURL, options: .atomic)
        operationGenerations.advanceAllGenerations()
        searchIndexCache.removeAll()
    }

    private func rollbackClearTransaction(
        paths: ClearTransactionPaths,
        movedDirectory: Bool,
        movedLegacyFile: Bool
    ) throws {
        do {
            if movedDirectory,
               FileManager.default.fileExists(atPath: directoryURL.path)
            {
                try FileManager.default.removeItem(at: directoryURL)
            }
            if movedDirectory,
               FileManager.default.fileExists(atPath: paths.backupDirectory.path)
            {
                try moveOperation(paths.backupDirectory, directoryURL)
            }
            if movedLegacyFile,
               FileManager.default.fileExists(atPath: paths.legacyBackupURL.path)
            {
                try moveOperation(paths.legacyBackupURL, legacyFileURL)
            }
            try? FileManager.default.removeItem(at: paths.privacyCleanupMarkerURL)
            try? FileManager.default.removeItem(at: paths.commitMarkerURL)
        } catch let rollbackError {
            let unresolvedBackupPaths = [paths.backupDirectory, paths.legacyBackupURL]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
                .map(\.path)
            sharedMutationState.unresolvedClearBackupPaths = unresolvedBackupPaths.isEmpty
                ? [paths.backupDirectory.path, paths.legacyBackupURL.path]
                : unresolvedBackupPaths
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "Failed to roll back conversation clear transaction",
                metadata: [
                    "error": rollbackError.localizedDescription,
                    "backup": paths.backupDirectory.path,
                ]
            )
            throw EncryptedStoreError.clearRollbackFailed(
                paths: sharedMutationState.unresolvedClearBackupPaths ?? []
            )
        }
    }

    private func cleanupCommittedClearBackups(
        _ committedBackups: [URL],
        parentDirectory: URL
    ) throws {
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
                            "backup": backupURL.path,
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
    }
}
