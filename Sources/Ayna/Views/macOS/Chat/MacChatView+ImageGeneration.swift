#if os(macOS)
//
//  MacChatView+ImageGeneration.swift
//  ayna
//
//  Image generation and multi-model messaging methods extracted from MacChatView.
//

import SwiftUI

// MARK: - Image Generation & Multi-Model Messaging

extension MacChatView {
    /// Finds the most recent generated or selected image in the conversation for editing context.
    func findPreviousImageForEditing() -> Data? {
        // Look for the most recent assistant message with an image
        // Prioritize selected responses from multi-model groups
        for message in conversation.messages.reversed() {
            guard message.role == .assistant, message.mediaType == .image else { continue }

            // If this message is part of a response group, only use it if it was selected
            if let groupId = message.responseGroupId {
                if let group = conversation.getResponseGroup(groupId),
                   group.selectedResponseId == message.id
                {
                    return message.effectiveImageData
                }
                // Skip unselected multi-model responses
                continue
            }

            // Single-model image - use it
            return message.effectiveImageData
        }
        return nil
    }

    func generateImage(prompt: String, model: String) {
        // Create placeholder assistant message with a known ID
        let messageId = UUID()
        let placeholderMessage = Message(
            id: messageId,
            role: .assistant,
            content: "",
            model: model,
            mediaType: .image
        )
        conversationManager.addMessage(to: conversation, message: placeholderMessage)

        // Check if we have a previous image to edit
        if let previousImage = findPreviousImageForEditing() {
            // Use image editing API for follow-up requests
            logChat("📝 Using image edit API with previous image context", level: .info)

            aiService.editImage(
                prompt: prompt,
                sourceImage: previousImage,
                model: model,
                onComplete: { imageData in
                    Task { @MainActor in
                        handleImageGenerationSuccess(imageData: imageData, messageId: messageId)
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        handleImageGenerationError(error: error, messageId: messageId)
                    }
                }
            )
        } else {
            // No previous image - use generation API
            aiService.generateImage(
                prompt: prompt,
                model: model,
                onComplete: { imageData in
                    Task { @MainActor in
                        handleImageGenerationSuccess(imageData: imageData, messageId: messageId)
                    }
                },
                onError: { error in
                    Task { @MainActor in
                        handleImageGenerationError(error: error, messageId: messageId)
                    }
                }
            )
        }
    }

    func handleImageGenerationSuccess(imageData: Data, messageId: UUID) {
        // Save image to disk
        var imagePath: String?
        do {
            imagePath = try AttachmentStorage.shared.save(data: imageData, extension: "png")
        } catch {
            logChat(
                "❌ Failed to save generated image: \(error.localizedDescription)", level: .error
            )
        }

        // Update the placeholder message with actual image using the proper method
        conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
            message.content = ""
            if let path = imagePath {
                message.imagePath = path
                message.imageData = nil // Don't store raw data if saved to disk
            } else {
                // Fallback to storing in message if save failed
                message.imageData = imageData
                message.imagePath = nil
            }
        }

        isGenerating = false
    }

    func handleImageGenerationError(error: Error, messageId _: UUID) {
        isGenerating = false
        errorMessage = ErrorPresenter.userMessage(for: error)
        errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)

        // Remove the empty assistant placeholder message since we show error in banner
        if let index = conversationManager.conversations.firstIndex(where: {
            $0.id == conversation.id
        }) {
            let lastIndex = conversationManager.conversations[index].messages.count - 1
            if lastIndex >= 0,
               conversationManager.conversations[index].messages[lastIndex].role == .assistant,
               conversationManager.conversations[index].messages[lastIndex].content.isEmpty
            {
                conversationManager.conversations[index].messages.remove(at: lastIndex)
            }
        }
    }

    /// Generates images from multiple models in parallel for comparison
    func generateMultiModelImages(prompt: String, models: [String]) {
        // Check if we have a previous image to edit
        let previousImage = findPreviousImageForEditing()

        // Create a response group for the multi-model comparison
        let responseGroupId = UUID()
        var responseEntries: [ResponseGroup.ResponseEntry] = []
        var messageIds: [String: UUID] = [:]

        // Create placeholder messages for each model
        for model in models {
            let messageId = UUID()
            messageIds[model] = messageId

            let placeholderMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId,
                mediaType: .image
            )
            conversationManager.addMessage(to: conversation, message: placeholderMessage)

            responseEntries.append(ResponseGroup.ResponseEntry(
                id: messageId,
                modelName: model,
                status: .streaming
            ))
        }

        // Create response group
        let userMessageId = conversation.messages.first(where: { $0.role == .user })?.id
            ?? conversation.messages.last(where: { $0.role == .user })?.id ?? UUID()
        let responseGroup = ResponseGroup(
            id: responseGroupId,
            userMessageId: userMessageId,
            responses: responseEntries
        )

        // Add response group to conversation
        if let index = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversationManager.conversations[index].responseGroups.append(responseGroup)
        }

        // Track completion state with actor-isolated counter
        let counter = MainActorCompletionCounter(total: models.count)

        // Log whether we're using edit or generation
        if previousImage != nil {
            logChat("📝 Using image edit API with previous image context for multi-model", level: .info)
        }

        // Generate/edit images in parallel
        for model in models {
            guard let messageId = messageIds[model] else { continue }

            let onComplete: @Sendable (Data) -> Void = { imageData in
                Task { @MainActor in
                    // Save image to disk
                    var imagePath: String?
                    do {
                        imagePath = try AttachmentStorage.shared.save(data: imageData, extension: "png")
                    } catch {
                        logChat(
                            "❌ Failed to save generated image: \(error.localizedDescription)",
                            level: .error
                        )
                    }

                    // Update the placeholder message with actual image
                    conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                        message.content = ""
                        if let path = imagePath {
                            message.imagePath = path
                            message.imageData = nil
                        } else {
                            message.imageData = imageData
                            message.imagePath = nil
                        }
                    }

                    // Update response group status
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                       let groupIndex = conversationManager.conversations[convIndex].responseGroups.firstIndex(where: { $0.id == responseGroupId }),
                       let entryIndex = conversationManager.conversations[convIndex].responseGroups[groupIndex].responses.firstIndex(where: { $0.id == messageId })
                    {
                        conversationManager.conversations[convIndex].responseGroups[groupIndex].responses[entryIndex].status = .completed
                    }

                    counter.increment()
                    if counter.isComplete {
                        isGenerating = false
                    }
                }
            }

            let onError: @Sendable (Error) -> Void = { error in
                Task { @MainActor in
                    logChat(
                        "❌ Image generation failed for \(model): \(error.localizedDescription)",
                        level: .error,
                        metadata: ["model": model]
                    )

                    // Update response group status to failed
                    if let convIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
                       let groupIndex = conversationManager.conversations[convIndex].responseGroups.firstIndex(where: { $0.id == responseGroupId }),
                       let entryIndex = conversationManager.conversations[convIndex].responseGroups[groupIndex].responses.firstIndex(where: { $0.id == messageId })
                    {
                        conversationManager.conversations[convIndex].responseGroups[groupIndex].responses[entryIndex].status = .failed
                    }

                    // Update message with error
                    conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                        message.content = "Image generation failed: \(error.localizedDescription)"
                    }

                    counter.increment()
                    if counter.isComplete {
                        isGenerating = false
                    }
                }
            }

            if let sourceImage = previousImage {
                // Use image editing API
                aiService.editImage(
                    prompt: prompt,
                    sourceImage: sourceImage,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            } else {
                // Use image generation API
                aiService.generateImage(
                    prompt: prompt,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            }
        }
    }

    // MARK: - Multi-Model Message Sending

    func sendMultiModelMessage(
        userMessageId: UUID,
        models: [String],
        temperature: Double
    ) {
        logChat(
            "🔀 Starting multi-model request",
            level: .info,
            metadata: ["models": models.joined(separator: ", ")]
        )

        // Get updated conversation
        guard let updatedConversation = conversationManager.conversations.first(where: {
            $0.id == conversation.id
        }) else {
            isGenerating = false
            return
        }

        // Create response group
        let responseGroupId = UUID()
        var responseGroup = ResponseGroup(id: responseGroupId, userMessageId: userMessageId)

        // Create placeholder messages for each model
        var messageIds: [String: UUID] = [:]
        for model in models {
            let messageId = UUID()
            messageIds[model] = messageId
            responseGroup.addResponse(messageId: messageId, modelName: model, status: .streaming)

            let placeholderMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                responseGroupId: responseGroupId
            )
            conversationManager.addMessage(to: conversation, message: placeholderMessage)
        }

        // Add response group to conversation
        conversationManager.addResponseGroup(to: conversation, group: responseGroup)

        // Prepare messages for API
        var messagesToSend = updatedConversation.getEffectiveHistory()
        if let systemPrompt = buildFullSystemPrompt(for: updatedConversation) {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messagesToSend.insert(systemMessage, at: 0)
        }

        // Capture necessary values for closures
        let conversationId = conversation.id

        // Send to all models in parallel
        aiService.sendToMultipleModels(
            messages: messagesToSend,
            models: models,
            temperature: temperature,
            onChunk: { model, chunk in
                Task { @MainActor in
                    guard let messageId = messageIds[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: {
                              $0.id == conversationId
                          }),
                          let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: {
                              $0.id == messageId
                          })
                    else { return }

                    conversationManager.conversations[convIndex].messages[msgIndex].content += chunk
                }
            },
            onModelComplete: { model in
                Task { @MainActor in
                    guard let messageId = messageIds[model] else { return }

                    // Update response group status
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }),
                        var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                    {
                        group.updateStatus(for: messageId, status: .completed)
                        conversationManager.conversations[convIndex].updateResponseGroup(group)
                    }

                    logChat(
                        "✅ Model completed in multi-model",
                        level: .info,
                        metadata: ["model": model]
                    )
                }
            },
            onAllComplete: {
                Task { @MainActor in
                    isGenerating = false
                    logChat("🏁 All models completed", level: .info)

                    // Save the conversation
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }) {
                        conversationManager.save(conversationManager.conversations[convIndex])
                    }
                }
            },
            onError: { model, error in
                Task { @MainActor in
                    guard let messageId = messageIds[model] else { return }

                    // Update response group status to failed
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }),
                        var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                    {
                        group.updateStatus(for: messageId, status: .failed)
                        conversationManager.conversations[convIndex].updateResponseGroup(group)
                    }

                    logChat(
                        "❌ Model failed in multi-model",
                        level: .error,
                        metadata: ["model": model, "error": error.localizedDescription]
                    )
                }
            },
            onPendingToolCall: { model, toolId, toolName, arguments in
                let argumentsWrapper = UncheckedSendableWrapper(arguments)
                Task { @MainActor in
                    guard let messageId = messageIds[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: {
                              $0.id == conversationId
                          }),
                          let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: {
                              $0.id == messageId
                          })
                    else { return }

                    // Store as pending tool call (will be activated on selection)
                    let anyCodableArgs = argumentsWrapper.value.reduce(into: [String: AnyCodable]()) { result, pair in
                        result[pair.key] = AnyCodable(pair.value)
                    }
                    let pendingCall = MCPToolCall(
                        id: toolId,
                        toolName: toolName,
                        arguments: anyCodableArgs
                    )

                    var pendingCalls = conversationManager.conversations[convIndex].messages[msgIndex].pendingToolCalls ?? []
                    pendingCalls.append(pendingCall)
                    conversationManager.conversations[convIndex].messages[msgIndex].pendingToolCalls = pendingCalls

                    logChat(
                        "🔧 Pending tool call stored",
                        level: .info,
                        metadata: ["model": model, "tool": toolName]
                    )
                }
            },
            onReasoning: nil
        )
    }
}
#endif
