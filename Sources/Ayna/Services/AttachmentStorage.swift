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
    private let dataCache = AttachmentDataCache.shared

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        attachmentsDirectory = appSupport.appendingPathComponent("Ayna/Attachments", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
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
            try data.write(to: fileURL)
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

    /// Loads data from a relative path, using cache to avoid repeated disk I/O
    func load(path: String) -> Data? {
        // Check cache first
        if let cached = dataCache.get(path) {
            return cached
        }

        // Load from disk
        let fileURL = attachmentsDirectory.appendingPathComponent(path)
        do {
            let data = try Data(contentsOf: fileURL)
            // Cache the data for future access
            dataCache.set(data, forKey: path)
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
}
