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

/// Manages storage of message attachments (images, files) on disk
/// to reduce the size of the encrypted conversation store.
final class AttachmentStorage: Sendable {
    static let shared = AttachmentStorage()

    private let attachmentsDirectory: URL
    private let dataCache: AttachmentDataCache

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
    func save(data: Data, extension: String = "dat") throws -> String {
        let filename = UUID().uuidString + "." + `extension`
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

    /// Returns cached data without touching disk.
    func cachedData(path: String) -> Data? {
        dataCache.get(path)
    }

    /// Loads data from a relative path, using cache to avoid repeated disk I/O
    func load(path: String) -> Data? {
        // Check cache first
        if let cached = dataCache.get(path) {
            return cached
        }

        let fileURL = attachmentsDirectory.appendingPathComponent(path)
        return Self.readData(at: fileURL, path: path, cache: dataCache)
    }

    /// Loads data from disk off the caller's actor, caching the result for future access.
    func loadData(path: String) async -> Data? {
        if let cached = dataCache.get(path) {
            return cached
        }

        let fileURL = attachmentsDirectory.appendingPathComponent(path)
        let dataCache = dataCache
        return await Task.detached(priority: .userInitiated) {
            Self.readData(at: fileURL, path: path, cache: dataCache)
        }.value
    }

    /// Deletes a file at the given relative path
    func delete(path: String) {
        // Remove from cache
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
}
