import CryptoKit
import Foundation
import os.log

extension EncryptedConversationStore {
    struct LegacyMigrationContext: Sendable {
        let keyData: Data
        let directory: URL
        let metadataDirectory: URL
        let stagingDirectory: URL
        let legacyFileURL: URL
        let mutationLock: MutationLock
        let operationGenerations: OperationGenerationRegistry
        let expectedGlobalGeneration: UInt64
    }

    nonisolated static func migrateLegacyStoreIfPresent(
        context: LegacyMigrationContext,
        logProgress: Bool
    ) async throws -> [Conversation]? {
        guard FileManager.default.fileExists(atPath: context.legacyFileURL.path) else {
            return nil
        }

        if logProgress {
            DiagnosticsLogger.log(
                .encryptedStore, level: .info, message: "Found legacy conversation file, migrating..."
            )
        }

        do {
            let conversations = try deduplicatedLegacyConversations(
                loadLegacyFile(at: context.legacyFileURL, keyData: context.keyData)
            )
            for conversation in conversations {
                let committed = try migrateLegacyConversation(conversation, context: context)
                guard committed != nil else { return [] }
            }
            let migrationFinished = try context.mutationLock.withLock { () -> Bool in
                guard context.operationGenerations.matchesGlobalGeneration(context.expectedGlobalGeneration) else {
                    return false
                }
                if FileManager.default.fileExists(atPath: context.legacyFileURL.path) {
                    try FileManager.default.removeItem(at: context.legacyFileURL)
                }
                return true
            }
            guard migrationFinished else { return [] }
            if logProgress {
                DiagnosticsLogger.log(.encryptedStore, level: .info, message: "Migration complete")
            }
            return try await loadCanonicalConversations(
                in: context.directory,
                keyData: context.keyData,
                mutationLock: context.mutationLock,
                operationGenerations: context.operationGenerations
            )
        } catch {
            if logProgress {
                DiagnosticsLogger.log(
                    .encryptedStore, level: .error, message: "Migration failed",
                    metadata: ["error": error.localizedDescription]
                )
            }
            throw error
        }
    }

    private nonisolated static func loadCanonicalConversations(
        in directory: URL,
        keyData: Data,
        mutationLock: MutationLock,
        operationGenerations: OperationGenerationRegistry
    ) async throws -> [Conversation] {
        let fileURLsById = try conversationFileURLsById(in: directory)
        // swiftlint:disable:next large_tuple
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
                                "error": error.localizedDescription,
                            ]
                        )
                        return (id, url, version, generation, nil)
                    }
                }
            }

            var conversations: [Conversation] = []
            conversations.reserveCapacity(snapshots.count)
            var failedCount = 0
            for try await (id, url, version, generation, conversation) in group {
                try Task.checkCancellation()
                let isCurrent = mutationLock.withLock {
                    operationGenerations.matches(generation, for: id)
                        && fileVersion(at: url) == version
                }
                guard isCurrent else { continue }
                if let conversation {
                    conversations.append(conversation)
                } else {
                    failedCount += 1
                }
            }
            guard failedCount == 0 else {
                DiagnosticsLogger.log(
                    .encryptedStore,
                    level: .error,
                    message: "❌ Refusing partial migrated conversation load",
                    metadata: ["failedCount": "\(failedCount)"]
                )
                throw EncryptedStoreError.unreadableConversationFiles(count: failedCount)
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

    private nonisolated static func migrateLegacyConversation(
        _ conversation: Conversation,
        context: LegacyMigrationContext
    ) throws -> Bool? {
        let fileURL = context.directory.appendingPathComponent("\(conversation.id.uuidString).enc")
        let expectedExistingVersion = fileVersion(at: fileURL)
        if expectedExistingVersion != nil {
            do {
                let canonicalConversation = try loadCancellable(from: fileURL, keyData: context.keyData)
                if canonicalConversation.id == conversation.id,
                   canonicalConversation.updatedAt >= conversation.updatedAt
                {
                    return context.mutationLock.withLock {
                        guard context.operationGenerations.matchesGlobalGeneration(context.expectedGlobalGeneration) else {
                            return nil
                        }
                        let generation = context.operationGenerations.currentGeneration(for: conversation.id)
                        guard generation.conversation == 0 else { return false }
                        guard fileVersion(at: fileURL) == expectedExistingVersion else { return nil }
                        return false
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }

        let preparedWrite = try prepareWrite(conversation, keyData: context.keyData)
        return try withStagedWrite(
            preparedWrite,
            stagingDirectory: context.stagingDirectory
        ) { stagedWrite -> Bool? in
            try context.mutationLock.withLock { () -> Bool? in
                guard context.operationGenerations.matchesGlobalGeneration(context.expectedGlobalGeneration) else {
                    return nil
                }
                let generation = context.operationGenerations.currentGeneration(for: conversation.id)
                guard generation.conversation == 0 else { return false }
                guard fileVersion(at: fileURL) == expectedExistingVersion else { return nil }
                try commit(
                    stagedWrite,
                    to: context.directory,
                    metadataDirectory: context.metadataDirectory
                )
                return true
            }
        }
    }
}
