//
//  ImageEditContext.swift
//  ayna
//
//  Chooses the source images for an image-generation request.
//

import Foundation

/// The images an image request edits instead of generating from scratch.
///
/// Images attached to the triggering user message take precedence. Without attachments,
/// the most recent generated (or selected multi-model) image continues the edit chain.
struct ImageEditContext: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// Images the user attached to the prompt; failing to load them is an error.
        case attachments
        /// The previous generated image; failing to load it falls back to generation.
        case previousImage
    }

    struct Reference: Equatable, Sendable {
        let fileName: String
        let mimeType: String
        let data: Data?
        let localPath: String?
    }

    let origin: Origin
    let references: [Reference]

    /// Resolves edit sources for `userMessage`, defaulting to the conversation's latest user message.
    static func resolve(in conversation: Conversation, userMessage: Message? = nil) -> ImageEditContext? {
        let triggeringMessage = userMessage ?? conversation.messages.last(where: { $0.role == .user })
        let attachments = (triggeringMessage?.attachments ?? [])
            .filter { OpenAIImageService.isEditableImageMIMEType($0.mimeType) }
            .filter { $0.data != nil || $0.localPath != nil }
            .prefix(OpenAIImageService.maxSourceImages)
        if !attachments.isEmpty {
            return ImageEditContext(
                origin: .attachments,
                references: attachments.map {
                    Reference(fileName: $0.fileName, mimeType: $0.mimeType, data: $0.data, localPath: $0.localPath)
                }
            )
        }

        guard let previousImage = previousGeneratedImage(in: conversation) else { return nil }
        return ImageEditContext(
            origin: .previousImage,
            references: [Reference(
                fileName: "image.png",
                mimeType: "image/png",
                data: previousImage.imageData,
                localPath: previousImage.imagePath
            )]
        )
    }

    /// Loads every reference. Missing user attachments throw; a missing previous image yields no sources.
    func loadSourceImages(
        loadData: @Sendable (String) async -> Data?
    ) async throws -> [OpenAIImageService.SourceImage] {
        var sourceImages: [OpenAIImageService.SourceImage] = []
        for reference in references {
            try Task.checkCancellation()
            var data = reference.data
            if data == nil, let localPath = reference.localPath {
                data = await loadData(localPath)
            }
            guard let data, !data.isEmpty else {
                guard origin == .attachments else { return [] }
                throw AynaError.fileOperationFailed(operation: "load", path: reference.fileName)
            }
            // A previous image may be JPEG or WebP when GPT Image output format was changed.
            let mimeType = origin == .previousImage ? Self.sniffedImageMIMEType(data) ?? reference.mimeType : reference.mimeType
            sourceImages.append(OpenAIImageService.SourceImage(
                data: data,
                mimeType: mimeType,
                fileName: reference.fileName
            ))
        }
        return sourceImages
    }

    static func sniffedImageMIMEType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.count >= 12, bytes[0 ..< 4] == [0x52, 0x49, 0x46, 0x46], bytes[8 ..< 12] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }

    private static func previousGeneratedImage(in conversation: Conversation) -> Message? {
        for message in conversation.messages.reversed() {
            guard message.role == .assistant, message.mediaType == .image,
                  message.imageData != nil || message.imagePath != nil
            else { continue }

            if let groupId = message.responseGroupId {
                if conversation.getResponseGroup(groupId)?.selectedResponseId == message.id {
                    return message
                }
                continue
            }
            return message
        }
        return nil
    }
}
