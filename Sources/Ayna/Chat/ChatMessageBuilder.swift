//
//  ChatMessageBuilder.swift
//  ayna
//
//  Extracted from MacChatView/MacNewChatView - handles message construction
//

#if os(macOS)

import Foundation

/// Builds user messages with optional app content context and file attachments
@MainActor
struct ChatMessageBuilder {
    // MARK: - App Content Formatting

    /// Formats the message content with optional app context prepended
    /// - Parameters:
    ///   - text: The user's message text
    ///   - appContent: Optional app content to include as context
    /// - Returns: The formatted message content
    static func formatContent(text: String, appContent: AppContent?) -> String {
        guard let appContent else {
            return text
        }

        let contextHeader = "---\n**Context from \(appContent.appName)**"
        let windowInfo = appContent.windowTitle.map { " (\($0))" } ?? ""
        let contentType = " [\(appContent.contentType.displayName)]"

        return """
        \(contextHeader)\(windowInfo)\(contentType)

        ```
        \(appContent.redacted.content)
        ```
        ---

        \(text)
        """
    }

    // MARK: - File Attachments

    /// Builds file attachments from a list of file URLs
    /// - Parameters:
    ///   - fileURLs: The URLs of files to attach
    ///   - saveToStorage: Whether to save files to AttachmentStorage (for existing chats)
    /// - Returns: Array of file attachments
    static func buildAttachments(
        from fileURLs: [URL],
        saveToStorage: Bool = false
    ) async -> [Message.FileAttachment] {
        var attachments: [Message.FileAttachment] = []

        for fileURL in fileURLs {
            let fileData = await Task.detached(priority: .utility) {
                try? Data(contentsOf: fileURL)
            }.value
            guard let fileData else {
                continue
            }

            let mimeType = MIMETypeHelper.getMimeType(for: fileURL)
            var localPath: String?

            if saveToStorage {
                let pathExtension = fileURL.pathExtension
                localPath = try? AttachmentStorage.shared.save(data: fileData, extension: pathExtension)
            }

            let attachment = Message.FileAttachment(
                fileName: fileURL.lastPathComponent,
                mimeType: mimeType,
                data: saveToStorage ? nil : fileData,
                localPath: localPath
            )
            attachments.append(attachment)
        }

        return attachments
    }

    // MARK: - User Message Creation

    /// Creates a user message with content and optional attachments
    /// - Parameters:
    ///   - text: The user's message text
    ///   - appContent: Optional app content to include as context
    ///   - fileURLs: URLs of files to attach
    ///   - saveToStorage: Whether to save files to AttachmentStorage
    /// - Returns: A configured Message with role .user
    static func createUserMessage(
        text: String,
        appContent: AppContent?,
        fileURLs: [URL],
        saveToStorage: Bool = false
    ) async -> Message {
        let content = formatContent(text: text, appContent: appContent)
        let attachments = await buildAttachments(from: fileURLs, saveToStorage: saveToStorage)

        return Message(
            role: .user,
            content: content,
            attachments: attachments.isEmpty ? nil : attachments
        )
    }
}

#endif
