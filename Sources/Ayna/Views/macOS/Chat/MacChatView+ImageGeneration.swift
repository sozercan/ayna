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
    /// Finds the storage path of the most recent generated or selected image for editing context.
    /// Returns a path (cheap) rather than loading full image data on MainActor.
    private func findPreviousImagePath() -> String? {
        for message in conversation.messages.reversed() {
            guard message.role == .assistant, message.mediaType == .image else { continue }

            if let groupId = message.responseGroupId {
                if let group = conversation.getResponseGroup(groupId),
                   group.selectedResponseId == message.id
                {
                    return message.imagePath
                }
                continue
            }

            return message.imagePath
        }
        return nil
    }

    func generateImage(prompt: String, model: String) {
        let coordinator = imageGenerationCoordinator
        let operationID = coordinator.beginOperation()

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

        let conversationManager = conversationManager
        let conversationID = conversation.id
        coordinator.onCancel(for: operationID) {
            conversationManager.removeMessage(conversationId: conversationID, messageId: messageId)
            if let conversation = conversationManager.conversation(byId: conversationID) {
                conversationManager.save(conversation)
            }
        }

        // Find previous image path (cheap, no disk I/O)
        let previousImagePath = findPreviousImagePath()

        // Own previous-image loading and the eventual transport under one logical request.
        let task = Task { @MainActor in
            let previousImage = await loadImageData(at: previousImagePath)
            guard coordinator.owns(operationID), !Task.isCancelled else { return }

            let onComplete: @Sendable (Data) -> Void = { imageData in
                coordinator.schedule(for: operationID) {
                    await handleImageGenerationSuccess(
                        imageData: imageData,
                        messageId: messageId,
                        operationID: operationID
                    )
                }
            }
            let onError: @Sendable (Error) -> Void = { error in
                coordinator.schedule(for: operationID) {
                    handleImageGenerationError(
                        error: error,
                        messageId: messageId,
                        operationID: operationID
                    )
                }
            }

            let request: AIImageRequest?
            if let previousImage {
                logChat("📝 Using image edit API with previous image context", level: .info)
                request = aiService.editImage(
                    prompt: prompt,
                    sourceImage: previousImage,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            } else {
                request = aiService.generateImage(
                    prompt: prompt,
                    model: model,
                    onComplete: onComplete,
                    onError: onError
                )
            }
            coordinator.track(request, for: operationID)
        }
        coordinator.track(task, for: operationID)
    }

    private func handleImageGenerationSuccess(
        imageData: Data,
        messageId: UUID,
        operationID: ImageGenerationCoordinator.OperationID
    ) async {
        let imagePath = await saveImageData(imageData)
        guard imageGenerationCoordinator.owns(operationID), !Task.isCancelled else {
            await deleteImageData(at: imagePath)
            return
        }

        if imagePath == nil {
            logChat("❌ Failed to save generated image to disk", level: .error)
        }

        let messageUpdated = conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
            message.content = ""
            if let path = imagePath {
                message.imagePath = path
                message.imageData = nil
            } else {
                message.imageData = imageData
                message.imagePath = nil
            }
        }
        guard messageUpdated else {
            await deleteImageData(at: imagePath)
            _ = imageGenerationCoordinator.finishOperation(operationID)
            isGenerating = false
            return
        }

        guard imageGenerationCoordinator.finishOperation(operationID) else { return }
        isGenerating = false
    }

    private func handleImageGenerationError(
        error: Error,
        messageId: UUID,
        operationID: ImageGenerationCoordinator.OperationID
    ) {
        guard imageGenerationCoordinator.finishOperation(operationID) else { return }

        isGenerating = false
        errorMessage = ErrorPresenter.userMessage(for: error)
        errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)

        // Remove the empty assistant placeholder message since we show error in banner
        conversationManager.removeMessage(conversationId: conversation.id, messageId: messageId)
        if let conversation = conversationManager.conversation(byId: conversation.id) {
            conversationManager.save(conversation)
        }
    }

    /// Generates images from multiple models in parallel for comparison
    func generateMultiModelImages(prompt: String, models: [String]) {
        let coordinator = imageGenerationCoordinator
        let operationID = coordinator.beginOperation()
        guard !models.isEmpty else {
            _ = coordinator.finishOperation(operationID)
            isGenerating = false
            return
        }

        // Find previous image path (cheap, no disk I/O)
        let previousImagePath = findPreviousImagePath()

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

        registerImageBatchCancellation(
            coordinator: coordinator,
            operationID: operationID,
            responseGroupID: responseGroupId,
            messageIDs: Array(messageIds.values)
        )

        let messageIdsByModel = messageIds
        let counter = MainActorCompletionCounter(total: models.count)

        // Own previous-image loading and every child transport under one batch operation.
        let task = Task { @MainActor in
            let previousImage = await loadImageData(at: previousImagePath)
            guard coordinator.owns(operationID), !Task.isCancelled else { return }

            if previousImage != nil {
                logChat("📝 Using image edit API with previous image context for multi-model", level: .info)
            }

            for model in models {
                guard let messageId = messageIdsByModel[model] else { continue }

                let onComplete: @Sendable (Data) -> Void = { imageData in
                    coordinator.schedule(for: operationID) {
                        let imagePath = await saveImageData(imageData)
                        guard coordinator.owns(operationID), !Task.isCancelled else {
                            await deleteImageData(at: imagePath)
                            return
                        }

                        updateImageResponseStatus(
                            responseGroupId: responseGroupId,
                            messageId: messageId,
                            status: .completed
                        )
                        let messageUpdated = conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                            message.content = ""
                            if let path = imagePath {
                                message.imagePath = path
                                message.imageData = nil
                            } else {
                                message.imageData = imageData
                                message.imagePath = nil
                            }
                        }
                        guard messageUpdated else {
                            await handleMissingImageMessage(
                                imagePath: imagePath,
                                responseGroupID: responseGroupId,
                                messageID: messageId,
                                counter: counter,
                                coordinator: coordinator,
                                operationID: operationID
                            )
                            return
                        }

                        counter.increment()
                        finishImageBatchIfComplete(
                            counter: counter,
                            coordinator: coordinator,
                            operationID: operationID
                        )
                    }
                }

                let onError: @Sendable (Error) -> Void = { error in
                    coordinator.schedule(for: operationID) {
                        logChat(
                            "❌ Image generation failed for \(model): \(error.localizedDescription)",
                            level: .error,
                            metadata: ["model": model]
                        )

                        updateImageResponseStatus(
                            responseGroupId: responseGroupId,
                            messageId: messageId,
                            status: .failed
                        )
                        conversationManager.updateMessage(in: conversation, messageId: messageId) { message in
                            message.content = "Image generation failed: \(error.localizedDescription)"
                        }

                        counter.increment()
                        finishImageBatchIfComplete(
                            counter: counter,
                            coordinator: coordinator,
                            operationID: operationID
                        )
                    }
                }

                let request: AIImageRequest? = if let previousImage {
                    aiService.editImage(
                        prompt: prompt,
                        sourceImage: previousImage,
                        model: model,
                        onComplete: onComplete,
                        onError: onError
                    )
                } else {
                    aiService.generateImage(
                        prompt: prompt,
                        model: model,
                        onComplete: onComplete,
                        onError: onError
                    )
                }
                coordinator.track(request, for: operationID)
            }
        }
        coordinator.track(task, for: operationID)
    }

    private func handleMissingImageMessage(
        imagePath: String?,
        responseGroupID: UUID,
        messageID: UUID,
        counter: MainActorCompletionCounter,
        coordinator: ImageGenerationCoordinator,
        operationID: ImageGenerationCoordinator.OperationID
    ) async {
        await deleteImageData(at: imagePath)
        updateImageResponseStatus(
            responseGroupId: responseGroupID,
            messageId: messageID,
            status: .failed
        )
        counter.increment()
        finishImageBatchIfComplete(
            counter: counter,
            coordinator: coordinator,
            operationID: operationID
        )
    }

    private func finishImageBatchIfComplete(
        counter: MainActorCompletionCounter,
        coordinator: ImageGenerationCoordinator,
        operationID: ImageGenerationCoordinator.OperationID
    ) {
        guard counter.isComplete, coordinator.finishOperation(operationID) else { return }
        if let conversation = conversationManager.conversation(byId: conversation.id) {
            conversationManager.save(conversation)
        }
        isGenerating = false
    }

    private func registerImageBatchCancellation(
        coordinator: ImageGenerationCoordinator,
        operationID: ImageGenerationCoordinator.OperationID,
        responseGroupID: UUID,
        messageIDs: [UUID]
    ) {
        let conversationManager = conversationManager
        let conversationID = conversation.id
        coordinator.onCancel(for: operationID) {
            guard let conversation = conversationManager.conversation(byId: conversationID),
                  let responseGroup = conversation.getResponseGroup(responseGroupID)
            else {
                return
            }
            let pendingMessageIDs = ImageGenerationCoordinator.pendingMessageIDs(
                in: responseGroup,
                candidates: messageIDs
            )
            for messageID in pendingMessageIDs {
                conversationManager.updateMessage(conversationId: conversationID, messageId: messageID) { message in
                    message.content = "Image generation stopped"
                }
                conversationManager.updateResponseGroupStatus(
                    conversationId: conversationID,
                    responseGroupId: responseGroupID,
                    messageId: messageID,
                    status: .failed
                )
            }
            if let conversation = conversationManager.conversation(byId: conversationID) {
                conversationManager.save(conversation)
            }
        }
    }

    private func updateImageResponseStatus(
        responseGroupId: UUID,
        messageId: UUID,
        status: ResponseGroup.ResponseStatus
    ) {
        guard let conversationIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversation.id }),
              let groupIndex = conversationManager.conversations[conversationIndex].responseGroups.firstIndex(where: {
                  $0.id == responseGroupId
              }),
              let entryIndex = conversationManager.conversations[conversationIndex].responseGroups[groupIndex]
              .responses.firstIndex(where: { $0.id == messageId })
        else {
            return
        }
        conversationManager.conversations[conversationIndex].responseGroups[groupIndex].responses[entryIndex].status = status
    }

    private func loadImageData(at path: String?) async -> Data? {
        guard let path else { return nil }
        let task = Task.detached(priority: .userInitiated) {
            AttachmentStorage.shared.load(path: path)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func saveImageData(_ imageData: Data) async -> String? {
        let task = Task.detached(priority: .userInitiated) {
            try? AttachmentStorage.shared.save(data: imageData, extension: "png")
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func deleteImageData(at path: String?) async {
        guard let path else { return }
        await Task.detached(priority: .utility) {
            AttachmentStorage.shared.delete(path: path)
        }.value
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
        let messageIds = Dictionary(uniqueKeysWithValues: models.map { ($0, UUID()) })
        for model in models {
            guard let messageId = messageIds[model] else { continue }
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

        let messageIdsByModel = messageIds

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
                    guard let messageId = messageIdsByModel[model],
                          let convIndex = conversationManager.conversations.firstIndex(where: {
                              $0.id == conversationId
                          }),
                          let msgIndex = conversationManager.conversations[convIndex].messages.firstIndex(where: {
                              $0.id == messageId
                          })
                    else { return }

                    conversationManager.conversations[convIndex].messages[msgIndex].content += chunk
                    // Persist during streaming so content isn't lost on quit
                    conversationManager.save(conversationManager.conversations[convIndex])
                }
            },
            onModelComplete: { model in
                Task { @MainActor in
                    guard let messageId = messageIdsByModel[model] else { return }

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

                    // Save the conversation immediately on completion
                    if let convIndex = conversationManager.conversations.firstIndex(where: {
                        $0.id == conversationId
                    }) {
                        conversationManager.saveImmediately(conversationManager.conversations[convIndex])
                    }
                }
            },
            onError: { model, error in
                Task { @MainActor in
                    guard let messageId = messageIdsByModel[model] else { return }

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
                    guard let messageId = messageIdsByModel[model],
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
