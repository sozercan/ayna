//
//  AttachmentStorage.swift
//  ayna
//
//  Created on 11/22/25.
//

import Foundation
import OSLog

/// Manages storage of message attachments (images, files) on disk
/// to reduce the size of the encrypted conversation store.
final class AttachmentStorage: Sendable {
    static let shared = AttachmentStorage()

    private let attachmentsDirectory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())

        attachmentsDirectory = appSupport.appendingPathComponent("Ayna/Attachments", isDirectory: true)

        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
    }

    /// Saves data to disk and returns the relative path
    func save(data: Data, extension: String = "dat") throws -> String {
        let filename = UUID().uuidString + "." + `extension`
        let fileURL = attachmentsDirectory.appendingPathComponent(filename)

        try data.write(to: fileURL)
        return filename
    }

    /// Loads data from a relative path
    func load(path: String) -> Data? {
        let fileURL = attachmentsDirectory.appendingPathComponent(path)
        return try? Data(contentsOf: fileURL)
    }

    /// Deletes a file at the given relative path
    func delete(path: String) {
        let fileURL = attachmentsDirectory.appendingPathComponent(path)
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Returns the full URL for a relative path (useful for QuickLook or sharing)
    func fileURL(for path: String) -> URL {
        return attachmentsDirectory.appendingPathComponent(path)
    }
}
