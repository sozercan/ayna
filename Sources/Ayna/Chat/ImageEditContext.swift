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
            sourceImages.append(OpenAIImageService.SourceImage(
                data: data,
                mimeType: reference.mimeType,
                fileName: reference.fileName
            ))
        }
        return sourceImages
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
