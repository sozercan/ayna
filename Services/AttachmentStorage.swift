//
//  AttachmentStorage.swift
//  ayna
//
//  Created on 11/22/25.
//

import Foundation

/// Manages storage of message attachments (images, files) on disk
/// to reduce the size of the encrypted conversation store.
final class AttachmentStorage: Sendable {
    static let shared = AttachmentStorage()

    private let attachmentsDirectory: URL

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

    /// Loads data from a relative path
    func load(path: String) -> Data? {
        let fileURL = attachmentsDirectory.appendingPathComponent(path)
        do {
            let data = try Data(contentsOf: fileURL)
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
