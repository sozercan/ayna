import CryptoKit
import Foundation
import os.log

extension EncryptedConversationStore {
    private struct FullTextSearchContext: Sendable {
        let query: String
        let conversationId: UUID
        let conversationURL: URL
        let searchIndexDirectoryURL: URL
        let stagingDirectoryURL: URL
        let persistBuiltIndex: Bool
        let keyData: Data
        let mutationLock: MutationLock
        let searchIndexCache: SearchIndexCache
    }

    private enum CachedSearchOutcome {
        case matched(Bool)
        case retry
        case miss
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
                        let context = FullTextSearchContext(
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
                        group.addTask {
                            try await Self.fullTextSearchMatches(context: context)
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
        context: FullTextSearchContext,
        allowRetry: Bool = true
    ) async throws -> (UUID, Bool) {
        try Task.checkCancellation()
        let searchIndexURL = searchIndexFileURL(
            for: context.conversationId,
            in: context.searchIndexDirectoryURL
        )

        do {
            switch searchCachedIndex(context: context) {
            case let .matched(matches):
                return (context.conversationId, matches)
            case .retry:
                return try await retryFullTextSearchIfAllowed(context: context, allowRetry: allowRetry)
            case .miss:
                break
            }

            switch try searchPersistedIndex(context: context, searchIndexURL: searchIndexURL) {
            case let .matched(matches):
                return (context.conversationId, matches)
            case .retry:
                return try await retryFullTextSearchIfAllowed(context: context, allowRetry: allowRetry)
            case .miss:
                break
            }

            return try await rebuildAndSearchIndex(
                context: context,
                searchIndexURL: searchIndexURL,
                allowRetry: allowRetry
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            DiagnosticsLogger.log(
                .encryptedStore,
                level: .error,
                message: "Failed to search conversation history",
                metadata: [
                    "id": context.conversationId.uuidString,
                    "error": error.localizedDescription,
                ]
            )
            return (context.conversationId, false)
        }
    }

    private nonisolated static func retryFullTextSearchIfAllowed(
        context: FullTextSearchContext,
        allowRetry: Bool
    ) async throws -> (UUID, Bool) {
        guard allowRetry else { return (context.conversationId, false) }
        return try await fullTextSearchMatches(context: context, allowRetry: false)
    }

    private nonisolated static func searchCachedIndex(
        context: FullTextSearchContext
    ) -> CachedSearchOutcome {
        guard let cached = context.mutationLock.withLock({ () -> SearchIndexCache.Entry? in
            guard let currentVersion = fileVersion(at: context.conversationURL),
                  let cached = context.searchIndexCache.entry(for: context.conversationId),
                  cached.fileVersion == currentVersion
            else {
                return nil
            }
            return cached
        }) else {
            return .miss
        }

        let matches = fieldsContainQuery(cached.searchableFields, query: context.query)
        let stillCurrent = context.mutationLock.withLock {
            fileVersion(at: context.conversationURL) == cached.fileVersion
        }
        return stillCurrent ? .matched(matches) : .retry
    }

    private nonisolated static func searchPersistedIndex(
        context: FullTextSearchContext,
        searchIndexURL: URL
    ) throws -> CachedSearchOutcome {
        let persistedSourceVersion = context.mutationLock.withLock {
            fileVersion(at: context.conversationURL)
        }
        guard let persistedSourceVersion,
              FileManager.default.fileExists(atPath: searchIndexURL.path),
              let index = try? loadSearchIndexCancellable(from: searchIndexURL, keyData: context.keyData),
              index.id == context.conversationId,
              index.sourceVersion == persistedSourceVersion,
              index.searchableFields.reduce(into: 0, { $0 += $1.utf8.count })
              <= SearchIndexCache.maximumEntryCost
        else {
            return .miss
        }

        let persisted = SearchIndexCache.Entry(
            fileVersion: persistedSourceVersion,
            searchableFields: index.searchableFields
        )
        let published = try context.mutationLock.withLock { () -> Bool in
            try Task.checkCancellation()
            guard fileVersion(at: context.conversationURL) == persistedSourceVersion else {
                return false
            }
            context.searchIndexCache.set(persisted, for: context.conversationId)
            return true
        }
        guard published else { return .retry }

        let matches = fieldsContainQuery(persisted.searchableFields, query: context.query)
        let stillCurrent = context.mutationLock.withLock {
            fileVersion(at: context.conversationURL) == persisted.fileVersion
        }
        return stillCurrent ? .matched(matches) : .retry
    }

    private nonisolated static func rebuildAndSearchIndex(
        context: FullTextSearchContext,
        searchIndexURL: URL,
        allowRetry: Bool
    ) async throws -> (UUID, Bool) {
        guard let sourceVersion = fileVersion(at: context.conversationURL) else {
            return (context.conversationId, false)
        }
        let conversation = try loadCancellable(from: context.conversationURL, keyData: context.keyData)
        let searchableFields = try cacheableSearchFields(from: conversation)
        let matches: Bool = if let searchableFields {
            fieldsContainQuery(searchableFields, query: context.query)
        } else {
            try conversationMatchesFullText(conversation, query: context.query)
        }

        let preparedIndexURL = try stageBuiltSearchIndex(
            searchableFields: searchableFields,
            sourceVersion: sourceVersion,
            context: context
        )
        defer {
            if let preparedIndexURL {
                try? FileManager.default.removeItem(at: preparedIndexURL)
            }
        }

        let committed = try commitBuiltSearchIndex(
            searchableFields: searchableFields,
            sourceVersion: sourceVersion,
            preparedIndexURL: preparedIndexURL,
            searchIndexURL: searchIndexURL,
            context: context
        )
        if !committed {
            return try await retryFullTextSearchIfAllowed(context: context, allowRetry: allowRetry)
        }

        try Task.checkCancellation()
        return (context.conversationId, matches)
    }

    private nonisolated static func stageBuiltSearchIndex(
        searchableFields: [String]?,
        sourceVersion: FileVersion,
        context: FullTextSearchContext
    ) throws -> URL? {
        guard context.persistBuiltIndex,
              let searchableFields,
              let encryptedIndex = try? encryptedData(
                  for: ConversationSearchIndex(
                      id: context.conversationId,
                      sourceVersion: sourceVersion,
                      searchableFields: searchableFields
                  ),
                  keyData: context.keyData
              )
        else {
            return nil
        }

        var preparedIndexURL: URL?
        do {
            try ensureDirectoryExists(context.stagingDirectoryURL)
            let temporaryURL = context.stagingDirectoryURL.appendingPathComponent(
                ".\(context.conversationId.uuidString).\(UUID().uuidString).search.tmp"
            )
            try encryptedIndex.write(to: temporaryURL, options: .atomic)
            preparedIndexURL = temporaryURL
            try Task.checkCancellation()
            return temporaryURL
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
                    "id": context.conversationId.uuidString,
                    "error": error.localizedDescription,
                ]
            )
            return nil
        }
    }

    private nonisolated static func commitBuiltSearchIndex(
        searchableFields: [String]?,
        sourceVersion: FileVersion,
        preparedIndexURL: URL?,
        searchIndexURL: URL,
        context: FullTextSearchContext
    ) throws -> Bool {
        try context.mutationLock.withLock { () -> Bool in
            try Task.checkCancellation()
            guard fileVersion(at: context.conversationURL) == sourceVersion else { return false }
            if let searchableFields {
                context.searchIndexCache.set(
                    .init(fileVersion: sourceVersion, searchableFields: searchableFields),
                    for: context.conversationId
                )
                if let preparedIndexURL {
                    do {
                        try ensureDirectoryExists(context.searchIndexDirectoryURL)
                        try installStagedFile(preparedIndexURL, at: searchIndexURL)
                    } catch {
                        DiagnosticsLogger.log(
                            .encryptedStore,
                            level: .error,
                            message: "Failed to persist conversation search index",
                            metadata: [
                                "id": context.conversationId.uuidString,
                                "error": error.localizedDescription,
                            ]
                        )
                    }
                }
            }
            return true
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

    nonisolated static func removeOrphanedSearchIndexes(
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

    nonisolated static func searchIndexFileURL(
        for conversationId: UUID,
        in searchIndexDirectory: URL
    ) -> URL {
        searchIndexDirectory.appendingPathComponent("\(conversationId.uuidString).search.enc")
    }
}
