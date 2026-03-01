//
//  ImageGenerationCoordinator.swift
//  ayna
//
//  Extracted from MacChatView/MacNewChatView - handles image generation logic
//

import Foundation

/// Coordinates image generation, including multi-model parallel generation
@MainActor
final class ImageGenerationCoordinator {
    /// Callback types for image generation results
    typealias ImageSuccessHandler = @Sendable (Data, UUID) -> Void
    typealias ImageErrorHandler = @Sendable (Error, UUID) -> Void
    typealias CompletionHandler = @Sendable () -> Void

    /// Configuration for multi-model image generation
    struct MultiModelConfig {
        let prompt: String
        let models: [String]
        let previousImage: Data?
        let userMessageId: UUID
        let aiService: AIService
    }

    /// Result of multi-model image generation setup
    struct MultiModelResult {
        let responseGroupId: UUID
        let messageIds: [String: UUID]
        let responseGroup: ResponseGroup
    }

    /// Generates a single image using the AI service
    /// - Parameters:
    ///   - prompt: The image generation prompt
    ///   - model: The model to use
    ///   - previousImage: Optional previous image for editing context
    ///   - aiService: The AI service instance
    ///   - onSuccess: Called with image data and message ID on success
    ///   - onError: Called with error and message ID on failure
    /// - Returns: The message ID of the placeholder message
    static func generateSingleImage(
        prompt: String,
        model: String,
        previousImage: Data?,
        aiService: AIService,
        onSuccess: @escaping ImageSuccessHandler,
        onError: @escaping ImageErrorHandler
    ) -> UUID {
        let messageId = UUID()

        if let previousImage {
            // Use image editing API for follow-up requests
            aiService.editImage(
                prompt: prompt,
                sourceImage: previousImage,
                model: model,
                onComplete: { imageData in
                    onSuccess(imageData, messageId)
                },
                onError: { error in
                    onError(error, messageId)
                }
            )
        } else {
            // Use generation API
            aiService.generateImage(
                prompt: prompt,
                model: model,
                onComplete: { imageData in
                    onSuccess(imageData, messageId)
                },
                onError: { error in
                    onError(error, messageId)
                }
            )
        }

        return messageId
    }

    /// Creates a placeholder message for image generation
    static func createImagePlaceholder(
        messageId: UUID,
        model: String,
        responseGroupId: UUID? = nil
    ) -> Message {
        Message(
            id: messageId,
            role: .assistant,
            content: "",
            model: model,
            responseGroupId: responseGroupId,
            mediaType: .image
        )
    }

    /// Generates images from multiple models in parallel
    /// - Parameters:
    ///   - config: Configuration for multi-model generation
    ///   - onImageSuccess: Called for each successful image generation
    ///   - onImageError: Called for each failed image generation
    ///   - onAllComplete: Called when all generations have finished
    /// - Returns: Result containing responseGroupId, messageIds, and responseGroup
    static func generateMultiModelImages(
        config: MultiModelConfig,
        onImageSuccess: @escaping ImageSuccessHandler,
        onImageError: @escaping ImageErrorHandler,
        onAllComplete: @escaping CompletionHandler
    ) -> MultiModelResult {
        let responseGroupId = UUID()
        var responseEntries: [ResponseGroup.ResponseEntry] = []
        var messageIds: [String: UUID] = [:]

        // Create message IDs and response entries for each model
        for model in config.models {
            let messageId = UUID()
            messageIds[model] = messageId

            responseEntries.append(ResponseGroup.ResponseEntry(
                id: messageId,
                modelName: model,
                status: .streaming
            ))
        }

        // Create response group
        let responseGroup = ResponseGroup(
            id: responseGroupId,
            userMessageId: config.userMessageId,
            responses: responseEntries
        )

        // Track completion with thread-safe counter
        let remainingCount = AsyncCounter(total: config.models.count)

        // Generate images in parallel
        for model in config.models {
            guard let messageId = messageIds[model] else { continue }

            let wrappedOnComplete: @Sendable (Data) -> Void = { imageData in
                Task { @MainActor in
                    onImageSuccess(imageData, messageId)
                    if await remainingCount.decrementAndCheck() {
                        onAllComplete()
                    }
                }
            }

            let wrappedOnError: @Sendable (Error) -> Void = { error in
                Task { @MainActor in
                    onImageError(error, messageId)
                    if await remainingCount.decrementAndCheck() {
                        onAllComplete()
                    }
                }
            }

            if let previousImage = config.previousImage {
                config.aiService.editImage(
                    prompt: config.prompt,
                    sourceImage: previousImage,
                    model: model,
                    onComplete: wrappedOnComplete,
                    onError: wrappedOnError
                )
            } else {
                config.aiService.generateImage(
                    prompt: config.prompt,
                    model: model,
                    onComplete: wrappedOnComplete,
                    onError: wrappedOnError
                )
            }
        }

        return MultiModelResult(
            responseGroupId: responseGroupId,
            messageIds: messageIds,
            responseGroup: responseGroup
        )
    }

    /// Saves image data to storage and returns the path
    static func saveImageToStorage(imageData: Data) throws -> String {
        try AttachmentStorage.shared.save(data: imageData, extension: "png")
    }
}

// MARK: - Async Counter

/// Thread-safe counter for tracking async completion
private actor AsyncCounter {
    private var remaining: Int

    init(total: Int) {
        remaining = total
    }

    func decrementAndCheck() -> Bool {
        remaining -= 1
        return remaining <= 0
    }
}
