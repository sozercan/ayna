//
//  ChatDraftContent.swift
//  Ayna
//

import Foundation
import UniformTypeIdentifiers

/// Shared rules for deciding whether a composer draft can form a provider request.
enum ChatDraftContent {
    /// Matches the strictest supported provider limit (Anthropic: 20 images per request).
    static let maximumImageCount = 20

    static func isSendable(
        text: String,
        fileURLs: [URL],
        inMemoryImageCount: Int
    ) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || fileURLs.contains(where: isImageFile)
            || inMemoryImageCount > 0
    }

    static func isSendable(
        text: String,
        attachments: [Message.FileAttachment]
    ) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachments.contains(where: isProviderImageAttachment)
    }

    static func remainingImageCapacity(
        fileURLs: [URL],
        inMemoryImageCount: Int
    ) -> Int {
        let imageFileCount = fileURLs.count(where: isImageFile)
        return max(0, maximumImageCount - imageFileCount - max(0, inMemoryImageCount))
    }

    static func messagesByIncludingUserMessageIfNeeded(
        _ userMessage: Message,
        in messages: [Message]
    ) -> [Message] {
        guard !messages.contains(where: { $0.id == userMessage.id }) else { return messages }
        return messages + [userMessage]
    }

    static func effectiveHistory(
        byEditingUserMessage messageID: UUID,
        newContent: String,
        in conversation: Conversation
    ) -> [Message]? {
        guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == messageID }),
              conversation.messages[messageIndex].role == .user
        else {
            return nil
        }

        var candidateConversation = conversation
        candidateConversation.messages = Array(conversation.messages.prefix(through: messageIndex))
        candidateConversation.messages[messageIndex].content = newContent
        return candidateConversation.getEffectiveHistory()
    }

    static func isImageFile(_ fileURL: URL) -> Bool {
        guard !fileURL.pathExtension.isEmpty,
              let contentType = UTType(filenameExtension: fileURL.pathExtension.lowercased())
        else {
            return false
        }

        return [.jpeg, .png, .gif, .webP].contains { supportedType in
            contentType.conforms(to: supportedType)
        }
    }

    private static func isProviderImageAttachment(_ attachment: Message.FileAttachment) -> Bool {
        ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(attachment.mimeType.lowercased())
    }
}
