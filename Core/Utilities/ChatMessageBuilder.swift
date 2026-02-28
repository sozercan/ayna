//
//  ChatMessageBuilder.swift
//  ayna
//

import Foundation

/// Utility for building user messages with attachments and app context.
enum ChatMessageBuilder {
    #if os(macOS)
    /// Creates a user message with optional app content and file attachments.
    @MainActor
    static func createUserMessage(
        text: String,
        appContent: AppContent?,
        fileURLs: [URL],
        saveToStorage: Bool
    ) -> Message {
        let attachments = buildAttachments(from: fileURLs, saveToStorage: saveToStorage)

        let finalContent: String
        if let appContent {
            let contextHeader = "---\n**Context from \(appContent.appName)**"
            let windowInfo = appContent.windowTitle.map { " (\($0))" } ?? ""
            let contentType = " [\(appContent.contentType.displayName)]"
            finalContent = """
            \(contextHeader)\(windowInfo)\(contentType)

            ```
            \(appContent.redacted.content)
            ```
            ---

            \(text)
            """
        } else {
            finalContent = text
        }

        return Message(
            role: .user,
            content: finalContent,
            attachments: attachments.isEmpty ? nil : attachments
        )
    }
    #endif

    /// Builds file attachments from URLs.
    @MainActor
    static func buildAttachments(from fileURLs: [URL], saveToStorage: Bool) -> [Message.FileAttachment] {
        var attachments: [Message.FileAttachment] = []
        for fileURL in fileURLs {
            guard let fileData = try? Data(contentsOf: fileURL) else { continue }
            let mimeType = mimeType(for: fileURL)

            if saveToStorage {
                let pathExtension = fileURL.pathExtension
                let localPath = try? AttachmentStorage.shared.save(data: fileData, extension: pathExtension)
                attachments.append(Message.FileAttachment(
                    fileName: fileURL.lastPathComponent,
                    mimeType: mimeType,
                    data: nil,
                    localPath: localPath
                ))
            } else {
                attachments.append(Message.FileAttachment(
                    fileName: fileURL.lastPathComponent,
                    mimeType: mimeType,
                    data: fileData
                ))
            }
        }
        return attachments
    }

    /// Returns MIME type for a file URL based on extension.
    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt", "md": "text/plain"
        case "json": "application/json"
        case "xml": "application/xml"
        default: "application/octet-stream"
        }
    }
}
