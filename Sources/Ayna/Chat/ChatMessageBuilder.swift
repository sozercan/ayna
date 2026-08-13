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
            pastedImages: [PastedImage] = [],
            saveToStorage: Bool = false,
            attachmentStorage: AttachmentStorage = .shared,
            fileDataLoader: @escaping @Sendable (URL) async -> Data? = { fileURL in
                await Task.detached(priority: .utility) {
                    try? Data(contentsOf: fileURL)
                }.value
            }
        ) async -> [Message.FileAttachment] {
            var attachments: [Message.FileAttachment] = []
            let attachmentGeneration = saveToStorage
                ? attachmentStorage.currentGeneration()
                : nil

            for fileURL in fileURLs {
                let fileData = await fileDataLoader(fileURL)
                guard let fileData else {
                    continue
                }

                let mimeType = MIMETypeHelper.getMimeType(for: fileURL)
                var localPath: String?

                if saveToStorage {
                    let pathExtension = fileURL.pathExtension
                    localPath = try? await attachmentStorage.saveData(
                        data: fileData,
                        extension: pathExtension,
                        generation: attachmentGeneration
                    )
                }

                let attachment = Message.FileAttachment(
                    fileName: fileURL.lastPathComponent,
                    mimeType: mimeType,
                    data: localPath == nil ? fileData : nil,
                    localPath: localPath
                )
                attachments.append(attachment)
            }

            for pastedImage in pastedImages {
                var localPath: String?
                if saveToStorage {
                    localPath = try? await attachmentStorage.saveData(
                        data: pastedImage.data,
                        extension: pastedImage.fileExtension,
                        generation: attachmentGeneration
                    )
                }

                attachments.append(Message.FileAttachment(
                    fileName: pastedImage.fileName,
                    mimeType: pastedImage.mimeType,
                    data: localPath == nil ? pastedImage.data : nil,
                    localPath: localPath
                ))
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
            pastedImages: [PastedImage] = [],
            saveToStorage: Bool = false,
            attachmentStorage: AttachmentStorage = .shared
        ) async -> Message {
            let content = formatContent(text: text, appContent: appContent)
            let attachments = await buildAttachments(
                from: fileURLs,
                pastedImages: pastedImages,
                saveToStorage: saveToStorage,
                attachmentStorage: attachmentStorage
            )

            return Message(
                role: .user,
                content: content,
                attachments: attachments.isEmpty ? nil : attachments
            )
        }
    }

#endif
