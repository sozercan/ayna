//
//  AttachmentStorage.swift
//  ayna
//
//  Created on 11/22/25.
//

import Foundation
import os

// MARK: - Image Data Cache

/// Thread-safe cache for attachment data to prevent repeated disk I/O.
/// Uses NSCache internally with a wrapper for Sendable conformance.
final class AttachmentDataCache: @unchecked Sendable {
    static let shared = AttachmentDataCache()

    private let cache = NSCache<NSString, NSData>()
    private let lock = NSLock()

    init() {
        // Limit cache to ~50MB of image data
        cache.totalCostLimit = 50 * 1024 * 1024
        // Limit to ~20 items
        cache.countLimit = 20
    }

    func get(_ key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key as NSString) as Data?
    }

    func set(_ data: Data, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
    }

    func remove(_ key: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAllObjects()
    }
}

// MARK: - Attachment Storage

struct AttachmentCleanupSnapshot: Sendable {
    static let empty = AttachmentCleanupSnapshot(fileNames: [])

    let fileNames: Set<String>
}

struct AttachmentStorageGeneration: Sendable, Equatable {
    fileprivate let value: UInt64
}

enum AttachmentStorageError: LocalizedError {
    case invalidCleanupPath(String)
    case unsupportedCleanupSymbolicLink(String)
    case privacyCleanupInProgress
    case staleGeneration
    case missingCleanupSnapshot

    var errorDescription: String? {
        switch self {
        case let .invalidCleanupPath(path):
            "Invalid attachment cleanup path: \(path)"
        case let .unsupportedCleanupSymbolicLink(path):
            "Attachment cleanup does not support a symbolic-link root: \(path)"
        case .privacyCleanupInProgress:
            "Attachment storage is being cleared"
        case .staleGeneration:
            "Attachment belongs to a cleared conversation generation"
        case .missingCleanupSnapshot:
            "Attachment cleanup scope is unavailable"
        }
    }
}

private enum AsyncLoadSource: Sendable {
    case cache(Data, generation: AttachmentStorageGeneration)
    case disk(fileURL: URL, generation: AttachmentStorageGeneration)
}

/// Manages storage of message attachments (images, files) on disk
/// to reduce the size of the encrypted conversation store.
final class AttachmentStorage: @unchecked Sendable {
    static let shared = AttachmentStorage()

    private let attachmentsDirectory: URL
    private let dataCache: AttachmentDataCache
    private let operationLock = NSLock()
    private var storageGeneration: UInt64 = 0
    private var cleanupFenceCount = 0

    init(
        directoryURL: URL? = nil,
        dataCache: AttachmentDataCache = .shared
    ) {
        self.dataCache = dataCache
        let fileManager = FileManager.default

        if let directoryURL {
            attachmentsDirectory = directoryURL
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            attachmentsDirectory = appSupport.appendingPathComponent("Ayna/Attachments", isDirectory: true)
        }

        do {
            try fileManager.createDirectory(
                at: attachmentsDirectory, withIntermediateDirectories: true
            )
            DiagnosticsLogger.log(
                .attachmentStorage,
                level: .info,
                message: "Initialized attachment storage",
                metadata: ["path": attachmentsDirectory.path]
            )
        } catch {
            DiagnosticsLogger.log(
                .attachmentStorage,
                level: .error,
                message: "Failed to create attachment directory",
                metadata: ["error": error.localizedDescription, "path": attachmentsDirectory.path]
            )
        }
    }

    /// Saves data to disk and returns the relative path
    func save(
        data: Data,
        extension: String = "dat",
        generation expectedGeneration: AttachmentStorageGeneration? = nil
    ) throws -> String {
        try operationLock.withLock {
            guard cleanupFenceCount == 0 else {
                throw AttachmentStorageError.privacyCleanupInProgress
            }
            if let expectedGeneration, expectedGeneration.value != storageGeneration {
                throw AttachmentStorageError.staleGeneration
            }
            let filename = UUID().uuidString + "." + Self.sanitizedExtension(`extension`)
            let fileURL = attachmentsDirectory.appendingPathComponent(filename)

            do {
                try data.write(to: fileURL, options: .atomic)
                dataCache.set(data, forKey: filename)
                DiagnosticsLogger.log(
                    .attachmentStorage,
                    level: .info,
                    message: "Saved attachment",
                    metadata: ["filename": filename, "size": "\(data.count)"]
                )
                return filename
            } catch {
                DiagnosticsLogger.log(
                    .attachmentStorage,
                    level: .error,
                    message: "Failed to save attachment",
                    metadata: ["error": error.localizedDescription, "filename": filename]
                )
                throw error
            }
        }
    }

    nonisolated static func sanitizedExtension(_ fileExtension: String) -> String {
        let components = fileExtension
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let sanitized = String(components.joined(separator: "_").prefix(32))
        return sanitized.isEmpty ? "dat" : sanitized
    }

    func currentGeneration() -> AttachmentStorageGeneration {
        operationLock.withLock {
            AttachmentStorageGeneration(value: storageGeneration)
        }
    }

    func isCurrentGeneration(_ generation: AttachmentStorageGeneration) -> Bool {
        operationLock.withLock {
            cleanupFenceCount == 0 && generation.value == storageGeneration
        }
    }

    /// Returns cached data without touching disk.
    func cachedData(path: String) -> Data? {
        operationLock.withLock {
            guard cleanupFenceCount == 0 else { return nil }
            return dataCache.get(path)
        }
    }

    /// Loads data from a relative path, using cache to avoid repeated disk I/O
    func load(path: String) -> Data? {
        operationLock.withLock {
            guard cleanupFenceCount == 0 else { return nil }
            if let cached = dataCache.get(path) {
                return cached
            }

            let fileURL = attachmentsDirectory.appendingPathComponent(path)
            return Self.readData(at: fileURL, path: path, cache: dataCache)
        }
    }

    /// Loads data from disk off the caller's actor, caching the result for future access.
    func loadData(path: String) async -> Data? {
        guard !Task.isCancelled else { return nil }

        let source = operationLock.withLock { () -> AsyncLoadSource? in
            guard cleanupFenceCount == 0 else { return nil }
            if let cached = dataCache.get(path) {
                return .cache(
                    cached,
                    generation: AttachmentStorageGeneration(value: storageGeneration)
                )
            }
            return .disk(
                fileURL: attachmentsDirectory.appendingPathComponent(path),
                generation: AttachmentStorageGeneration(value: storageGeneration)
            )
        }

        guard let source else { return nil }
        switch source {
        case let .cache(data, readGeneration):
            guard !Task.isCancelled else { return nil }
            return operationLock.withLock {
                guard cleanupFenceCount == 0,
                      readGeneration.value == storageGeneration
                else {
                    return nil
                }
                return data
            }
        case let .disk(fileURL, readGeneration):
            let readTask = Task.detached(priority: .userInitiated) { () -> Data? in
                do {
                    return try Self.readDataCancellable(at: fileURL)
                } catch is CancellationError {
                    return nil
                } catch {
                    DiagnosticsLogger.log(
                        .attachmentStorage,
                        level: .error,
                        message: "Failed to load attachment",
                        metadata: ["error": error.localizedDescription, "path": path]
                    )
                    return nil
                }
            }

            return await withTaskCancellationHandler {
                guard !Task.isCancelled else {
                    readTask.cancel()
                    return nil
                }
                guard let data = await readTask.value,
                      !Task.isCancelled
                else {
                    return nil
                }

                return self.operationLock.withLock {
                    guard self.cleanupFenceCount == 0,
                          readGeneration.value == self.storageGeneration,
                          FileManager.default.fileExists(atPath: fileURL.path)
                    else {
                        return nil
                    }
                    if let cached = self.dataCache.get(path) {
                        return cached
                    }
                    self.dataCache.set(data, forKey: path)
                    return data
                }
            } onCancel: {
                readTask.cancel()
            }
        }
    }

    /// Deletes a file at the given relative path
    func delete(path: String) {
        operationLock.withLock {
            dataCache.remove(path)

            let fileURL = attachmentsDirectory.appendingPathComponent(path)
            do {
                try FileManager.default.removeItem(at: fileURL)
                DiagnosticsLogger.log(
                    .attachmentStorage,
                    level: .info,
                    message: "Deleted attachment",
                    metadata: ["path": path]
                )
            } catch {
                DiagnosticsLogger.log(
                    .attachmentStorage,
                    level: .error,
                    message: "Failed to delete attachment",
                    metadata: ["error": error.localizedDescription, "path": path]
                )
            }
        }
    }

    /// Captures the attachment files currently owned by a clear request.
    func cleanupSnapshot() throws -> AttachmentCleanupSnapshot {
        try operationLock.withLock {
            try makeCleanupSnapshot()
        }
    }

    func beginCleanup() {
        operationLock.withLock {
            storageGeneration &+= 1
            cleanupFenceCount += 1
        }
    }

    func beginCleanupSnapshot() throws -> AttachmentCleanupSnapshot {
        beginCleanup()
        do {
            return try cleanupSnapshot()
        } catch {
            finishCleanup()
            throw error
        }
    }

    func finishCleanup() {
        operationLock.withLock {
            cleanupFenceCount = max(0, cleanupFenceCount - 1)
        }
    }

    /// Deletes the files captured by a clear request and clears the in-process cache.
    func clear(_ snapshot: AttachmentCleanupSnapshot) throws {
        try operationLock.withLock {
            let fileManager = FileManager.default
            do {
                try validateCleanupRoot(fileManager: fileManager)
                try fileManager.createDirectory(
                    at: attachmentsDirectory,
                    withIntermediateDirectories: true
                )
                let rootDirectory = attachmentsDirectory.standardizedFileURL
                let fileURLs = try snapshot.fileNames.map { fileName -> URL in
                    let fileURL = attachmentsDirectory
                        .appendingPathComponent(fileName)
                        .standardizedFileURL
                    guard !fileName.isEmpty,
                          fileName != ".",
                          fileName != "..",
                          fileName == (fileName as NSString).lastPathComponent,
                          !fileName.contains("/"),
                          fileURL.deletingLastPathComponent() == rootDirectory
                    else {
                        throw AttachmentStorageError.invalidCleanupPath(fileName)
                    }
                    return fileURL
                }
                dataCache.removeAll()
                for fileURL in fileURLs {
                    do {
                        try fileManager.removeItem(at: fileURL)
                    } catch let error as CocoaError where error.code == .fileNoSuchFile {
                        continue
                    }
                }
                DiagnosticsLogger.log(
                    .attachmentStorage,
                    level: .info,
                    message: "Cleared attachment snapshot",
                    metadata: [
                        "path": attachmentsDirectory.path,
                        "count": "\(snapshot.fileNames.count)"
                    ]
                )
            } catch {
                DiagnosticsLogger.log(
                    .attachmentStorage,
                    level: .error,
                    message: "Failed to clear attachment storage",
                    metadata: ["error": error.localizedDescription, "path": attachmentsDirectory.path]
                )
                throw error
            }
        }
    }

    /// Deletes every attachment present when the operation begins.
    func clearAll() throws {
        let snapshot = try beginCleanupSnapshot()
        defer { finishCleanup() }
        try clear(snapshot)
    }

    /// Returns the full URL for a relative path (useful for QuickLook or sharing)
    func fileURL(for path: String) -> URL {
        attachmentsDirectory.appendingPathComponent(path)
    }

    private nonisolated static func readData(
        at fileURL: URL,
        path: String,
        cache: AttachmentDataCache
    ) -> Data? {
        do {
            let data = try Data(contentsOf: fileURL)
            cache.set(data, forKey: path)
            return data
        } catch {
            DiagnosticsLogger.log(
                .attachmentStorage,
                level: .error,
                message: "Failed to load attachment",
                metadata: ["error": error.localizedDescription, "path": path]
            )
            return nil
        }
    }

    private func makeCleanupSnapshot() throws -> AttachmentCleanupSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: attachmentsDirectory.path) else {
            return .empty
        }
        try validateCleanupRoot(fileManager: fileManager)
        let fileNames = try fileManager.contentsOfDirectory(
            at: attachmentsDirectory,
            includingPropertiesForKeys: nil
        ).reduce(into: Set<String>()) { result, url in
            result.insert(url.lastPathComponent)
        }
        return AttachmentCleanupSnapshot(fileNames: fileNames)
    }

    private func validateCleanupRoot(fileManager: FileManager) throws {
        let attributes = try fileManager.attributesOfItem(atPath: attachmentsDirectory.path)
        guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw AttachmentStorageError.unsupportedCleanupSymbolicLink(attachmentsDirectory.path)
        }
    }

    private nonisolated static func readDataCancellable(at fileURL: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var data = Data()
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
}
