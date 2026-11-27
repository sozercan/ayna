import CryptoKit
import Foundation
import os.log

extension EncryptedConversationStore {
    private struct MetadataLoadContext: Sendable {
        let directoryURL: URL
        let metadataDirectoryURL: URL
        let searchIndexDirectoryURL: URL
        let stagingDirectoryURL: URL
        let keyData: Data
        let mutationLock: MutationLock
        let operationGenerations: OperationGenerationRegistry
        let loadGeneration: UInt64
    }

    private struct MetadataCommitCandidate {
        let metadata: ConversationMetadata
        let sourceVersion: FileVersion
        let shouldPersistSidecar: Bool
        let conversationId: UUID
        let conversationURL: URL
        let expectedGeneration: OperationGenerationRegistry.Generation
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
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                let keyData = try keyCache.keyData()
                let migrationContext = LegacyMigrationContext(
                    keyData: keyData,
                    directory: directoryURL,
                    metadataDirectory: metadataDirectoryURL,
                    stagingDirectory: stagingDirectoryURL,
                    legacyFileURL: legacyFileURL,
                    mutationLock: mutationLock,
                    operationGenerations: operationGenerations,
                    expectedGlobalGeneration: loadGeneration
                )
                if let migrated = try await Self.migrateLegacyStoreIfPresent(
                    context: migrationContext,
                    logProgress: true
                ) {
                    return migrated
                }
            }

            let encryptedFileURLs = try Self.conversationFileURLs(in: directoryURL)
            guard !encryptedFileURLs.isEmpty else {
                return []
            }

            let keyData = try keyCache.keyData()
            let (conversations, failedCount) = await Self.loadEncryptedConversations(
                from: encryptedFileURLs,
                keyData: keyData
            )

            guard operationGenerations.matchesGlobalGeneration(loadGeneration) else { return [] }
            guard failedCount == 0 else {
                DiagnosticsLogger.log(
                    .encryptedStore, level: .error,
                    message: "❌ Refusing partial conversation load",
                    metadata: ["failedCount": "\(failedCount)"]
                )
                throw EncryptedStoreError.unreadableConversationFiles(count: failedCount)
            }
            return conversations
        }.value
    }

    private nonisolated static func loadEncryptedConversations(
        from encryptedFileURLs: [URL],
        keyData: Data
    ) async -> ([Conversation], Int) {
        await withTaskGroup(of: Conversation?.self) { group in
            for url in encryptedFileURLs {
                group.addTask {
                    do {
                        return try Self.load(from: url, keyData: keyData)
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
            return (conversations, failedCount)
        }
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
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                let keyData = try keyCache.keyData()
                let migrationContext = LegacyMigrationContext(
                    keyData: keyData,
                    directory: directoryURL,
                    metadataDirectory: metadataDirectoryURL,
                    stagingDirectory: stagingDirectoryURL,
                    legacyFileURL: legacyFileURL,
                    mutationLock: mutationLock,
                    operationGenerations: operationGenerations,
                    expectedGlobalGeneration: loadGeneration
                )
                if let migrated = try await Self.migrateLegacyStoreIfPresent(
                    context: migrationContext,
                    logProgress: false
                ) {
                    return migrated
                        .map(ConversationMetadata.init(conversation:))
                        .sorted { $0.updatedAt > $1.updatedAt }
                }
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

            let keyData = try keyCache.keyData()
            let context = MetadataLoadContext(
                directoryURL: directoryURL,
                metadataDirectoryURL: metadataDirectoryURL,
                searchIndexDirectoryURL: searchIndexDirectoryURL,
                stagingDirectoryURL: stagingDirectoryURL,
                keyData: keyData,
                mutationLock: mutationLock,
                operationGenerations: operationGenerations,
                loadGeneration: loadGeneration
            )
            return try await Self.loadValidatedConversationMetadata(
                conversationFileURLsById: conversationFileURLsById,
                context: context
            )
        }.value
    }

    private nonisolated static func loadValidatedConversationMetadata(
        conversationFileURLsById: [UUID: URL],
        context: MetadataLoadContext
    ) async throws -> [ConversationMetadata] {
        let validConversationIds = Set(conversationFileURLsById.keys)
        let conversationGenerations = conversationFileURLsById.keys.reduce(into: [:]) { generations, id in
            generations[id] = context.operationGenerations.currentGeneration(for: id)
        }
        let conversationFileVersions = conversationFileURLsById.reduce(into: [UUID: FileVersion]()) { versions, pair in
            if let version = fileVersion(at: pair.value) {
                versions[pair.key] = version
            }
        }

        let (currentSidecarMetadata, backfilledMetadata) = try await loadSidecarAndBackfilledMetadata(
            conversationFileURLsById: conversationFileURLsById,
            validConversationIds: validConversationIds,
            context: context
        )
        guard context.operationGenerations.matchesGlobalGeneration(context.loadGeneration) else { return [] }

        let metadataPairs = currentSidecarMetadata.map { ($0.key, $0.value) }
            + backfilledMetadata.map { ($0.key, $0.value) }
        var validMetadata: [UUID: ConversationMetadata] = [:]
        for (id, initialMetadata) in metadataPairs {
            try Task.checkCancellation()
            guard let generation = conversationGenerations[id],
                  let conversationURL = conversationFileURLsById[id],
                  let sourceVersion = conversationFileVersions[id]
            else {
                continue
            }
            if let committedMetadata = try commitValidatedMetadataEntry(
                initialMetadata,
                conversationId: id,
                conversationURL: conversationURL,
                sourceVersion: sourceVersion,
                generation: generation,
                shouldPersistSidecar: backfilledMetadata[id] != nil,
                context: context
            ) {
                validMetadata[id] = committedMetadata
            }
        }

        guard context.operationGenerations.matchesGlobalGeneration(context.loadGeneration) else { return [] }
        let unreadableConversationIds = validConversationIds.filter { id in
            guard validMetadata[id] == nil,
                  let generation = conversationGenerations[id]
            else {
                return false
            }
            return context.operationGenerations.matches(generation, for: id)
        }
        guard unreadableConversationIds.isEmpty else {
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "❌ Refusing partial conversation metadata load",
                metadata: ["failedCount": "\(unreadableConversationIds.count)"]
            )
            throw EncryptedStoreError.unreadableConversationFiles(
                count: unreadableConversationIds.count
            )
        }
        return validMetadata.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private nonisolated static func loadSidecarAndBackfilledMetadata(
        conversationFileURLsById: [UUID: URL],
        validConversationIds: Set<UUID>,
        context: MetadataLoadContext
    ) async throws -> (current: [UUID: ConversationMetadata], backfilled: [UUID: ConversationMetadata]) {
        let metadataFileURLsById = try metadataFileURLsById(in: context.metadataDirectoryURL)
        let validMetadataFileURLsById = metadataFileURLsById.filter {
            validConversationIds.contains($0.key)
        }
        let sidecarMetadata = await loadMetadataSidecars(
            metadataFileURLsById: validMetadataFileURLsById,
            keyData: context.keyData
        )
        let staleMetadataIds = Set<UUID>(validMetadataFileURLsById.compactMap { id, metadataURL in
            guard let conversationURL = conversationFileURLsById[id],
                  let metadata = sidecarMetadata[id],
                  metadata.requiresBackfill
                  || sidecarIsOlderThanConversation(
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
        let backfilledMetadata = await loadFullConversationsAsMetadata(
            conversationFileURLsById: missingOrStaleMetadata,
            keyData: context.keyData
        )
        return (currentSidecarMetadata, backfilledMetadata)
    }

    private nonisolated static func commitValidatedMetadataEntry(
        _ initialMetadata: ConversationMetadata,
        conversationId: UUID,
        conversationURL: URL,
        sourceVersion: FileVersion,
        generation: OperationGenerationRegistry.Generation,
        shouldPersistSidecar: Bool,
        context: MetadataLoadContext
    ) throws -> ConversationMetadata? {
        var metadata = initialMetadata
        var effectiveSourceVersion = sourceVersion
        var effectiveGeneration = generation
        var persistSidecar = shouldPersistSidecar
        let currentVersion = fileVersion(at: conversationURL)
        if !context.operationGenerations.matches(effectiveGeneration, for: conversationId)
            || effectiveSourceVersion != currentVersion
        {
            guard let refreshed = try loadStableFullMetadata(
                conversationURL: conversationURL,
                keyData: context.keyData
            ) else {
                return nil
            }
            metadata = refreshed.metadata
            effectiveSourceVersion = refreshed.sourceVersion
            effectiveGeneration = context.operationGenerations.currentGeneration(for: conversationId)
            persistSidecar = true
        }

        var committed = try commitMetadataCandidate(
            MetadataCommitCandidate(
                metadata: metadata,
                sourceVersion: effectiveSourceVersion,
                shouldPersistSidecar: persistSidecar,
                conversationId: conversationId,
                conversationURL: conversationURL,
                expectedGeneration: effectiveGeneration
            ),
            context: context
        )

        if !committed,
           context.operationGenerations.matchesGlobalGeneration(context.loadGeneration),
           let refreshed = try loadStableFullMetadata(
               conversationURL: conversationURL,
               keyData: context.keyData
           )
        {
            metadata = refreshed.metadata
            effectiveGeneration = context.operationGenerations.currentGeneration(for: conversationId)
            committed = try commitMetadataCandidate(
                MetadataCommitCandidate(
                    metadata: metadata,
                    sourceVersion: refreshed.sourceVersion,
                    shouldPersistSidecar: true,
                    conversationId: conversationId,
                    conversationURL: conversationURL,
                    expectedGeneration: effectiveGeneration
                ),
                context: context
            )
        }

        return committed ? metadata : nil
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
        let saveCommitOperation = saveCommitOperation
        let saveGeneration = operationGenerations.currentGeneration(for: conversation.id)

        let saveTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let keyData = try keyCache.keyData()
            let preparedWrite = try Self.prepareWrite(conversation, keyData: keyData)
            try Task.checkCancellation()
            let stagedWrite = try Self.stage(
                preparedWrite,
                in: stagingDirectoryURL
            )
            defer { Self.cleanup(stagedWrite) }
            try Task.checkCancellation()
            try await saveCommitOperation(conversation.id)
            try Task.checkCancellation()
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
                                "error": error.localizedDescription,
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
        let metadataRemovalOperation = metadataRemovalOperation
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
                let searchIndexURL = Self.searchIndexFileURL(
                    for: conversationId,
                    in: searchIndexDirectoryURL
                )
                if FileManager.default.fileExists(atPath: searchIndexURL.path) {
                    try FileManager.default.removeItem(at: searchIndexURL)
                }

                for metadataURL in try Self.metadataFileURLs(matching: conversationId, in: metadataDirectoryURL) {
                    do {
                        try metadataRemovalOperation(metadataURL)
                    } catch {
                        DiagnosticsLogger.log(
                            .encryptedStore,
                            level: .error,
                            message: "Failed to remove conversation metadata during deletion",
                            metadata: ["id": conversationId.uuidString, "error": error.localizedDescription]
                        )
                        throw error
                    }
                }

                for fileURL in try Self.conversationFileURLs(matching: conversationId, in: directoryURL) {
                    try FileManager.default.removeItem(at: fileURL)
                }

                operationGenerations.advanceGeneration(for: conversationId)
                searchIndexCache.remove(conversationId)
            }
        }.value
    }

    nonisolated static func load(from url: URL, keyData: Data) throws -> Conversation {
        let encryptedData = try Data(contentsOf: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(Conversation.self, from: plaintext)
    }

    nonisolated static func loadCancellable(from url: URL, keyData: Data) throws -> Conversation {
        let encryptedData = try readDataCancellable(from: url)
        let box = try AES.GCM.SealedBox(combined: encryptedData)
        let key = SymmetricKey(data: keyData)
        let plaintext = try AES.GCM.open(box, using: key)
        try Task.checkCancellation()
        let conversation = try JSONDecoder().decode(Conversation.self, from: plaintext)
        try Task.checkCancellation()
        return conversation
    }

    nonisolated static func readDataCancellable(from url: URL) throws -> Data {
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

    nonisolated static func prepareWrite(
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

    nonisolated static func withStagedWrite<T>(
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

    nonisolated static func stage(
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

    nonisolated static func commit(
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

    nonisolated static func installStagedFile(_ stagedURL: URL, at destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destinationURL)
        }
    }

    nonisolated static func cleanup(_ stagedWrite: StagedConversationWrite) {
        try? FileManager.default.removeItem(at: stagedWrite.conversationTemporaryURL)
        if let metadataTemporaryURL = stagedWrite.metadataTemporaryURL {
            try? FileManager.default.removeItem(at: metadataTemporaryURL)
        }
    }

    nonisolated static func encryptedData(
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

    nonisolated static func fileVersion(at url: URL) -> FileVersion? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .fileSizeKey,
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
        _ candidate: MetadataCommitCandidate,
        context: MetadataLoadContext
    ) throws -> Bool {
        var stagedMetadataURL: URL?
        if candidate.shouldPersistSidecar {
            do {
                let encryptedMetadata = try encryptedData(for: candidate.metadata, keyData: context.keyData)
                try ensureDirectoryExists(context.stagingDirectoryURL)
                let temporaryURL = context.stagingDirectoryURL.appendingPathComponent(
                    ".\(candidate.conversationId.uuidString).\(UUID().uuidString).metadata.tmp"
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
                    metadata: ["id": candidate.conversationId.uuidString, "error": error.localizedDescription]
                )
            }
        }
        defer {
            if let stagedMetadataURL {
                try? FileManager.default.removeItem(at: stagedMetadataURL)
            }
        }

        return context.mutationLock.withLock {
            guard context.operationGenerations.matchesGlobalGeneration(context.loadGeneration),
                  context.operationGenerations.matches(candidate.expectedGeneration, for: candidate.conversationId),
                  fileVersion(at: candidate.conversationURL) == candidate.sourceVersion
            else {
                return false
            }

            if let stagedMetadataURL {
                do {
                    try ensureDirectoryExists(context.metadataDirectoryURL)
                    let metadataURL = metadataFileURL(
                        for: candidate.conversationId,
                        in: context.metadataDirectoryURL
                    )
                    try installStagedFile(stagedMetadataURL, at: metadataURL)
                } catch {
                    DiagnosticsLogger.log(
                        .encryptedStore,
                        level: .error,
                        message: "Failed to save conversation metadata sidecar",
                        metadata: ["id": candidate.conversationId.uuidString, "error": error.localizedDescription]
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

    nonisolated static func conversationFileURLs(in directory: URL) throws -> [URL] {
        try conversationFileURLsById(in: directory).values.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    nonisolated static func conversationFileURLsById(in directory: URL) throws -> [UUID: URL] {
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
                "discarded": discarded.lastPathComponent,
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

    nonisolated static func metadataFileURL(for conversationId: UUID, in metadataDirectory: URL) -> URL {
        metadataDirectory.appendingPathComponent("\(conversationId.uuidString).metadata.enc")
    }

    nonisolated static func ensureDirectoryExists(_ directory: URL) throws {
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
