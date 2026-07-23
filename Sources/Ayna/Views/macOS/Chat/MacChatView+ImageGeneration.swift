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

        private func isImageRequestCurrent(
            messageId: UUID,
            attachmentGeneration: AttachmentStorageGeneration
        ) -> Bool {
            guard imageRequestTracker.isActive(messageId),
                  AttachmentStorage.shared.isCurrentGeneration(attachmentGeneration),
                  let currentConversation = conversationManager.conversations.first(where: {
                      $0.id == conversation.id
                  })
            else {
                return false
            }
            return currentConversation.messages.contains { $0.id == messageId }
        }

        private func finalizeInvalidatedImageRequest(_ messageId: UUID) {
            guard imageRequestTracker.finish(messageId) else { return }
            if let conversationIndex = conversationManager.conversations.firstIndex(where: {
                $0.id == conversation.id
            }) {
                if let messageIndex = conversationManager.conversations[conversationIndex].messages.firstIndex(where: {
                    $0.id == messageId
                }) {
                    conversationManager.conversations[conversationIndex].messages[messageIndex].content =
                        "Image generation cancelled because conversation history changed"
                    conversationManager.conversations[conversationIndex].messages[messageIndex].mediaType = nil
                    conversationManager.conversations[conversationIndex].messages[messageIndex].imageData = nil
                    conversationManager.conversations[conversationIndex].messages[messageIndex].imagePath = nil
                }
                for groupIndex in conversationManager.conversations[conversationIndex].responseGroups.indices {
                    for responseIndex in conversationManager.conversations[conversationIndex]
                        .responseGroups[groupIndex].responses.indices
                        where conversationManager.conversations[conversationIndex]
                        .responseGroups[groupIndex].responses[responseIndex].id == messageId
                    {
                        conversationManager.conversations[conversationIndex]
                            .responseGroups[groupIndex].responses[responseIndex].status = .failed
                    }
                }
                conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            }
        }

        func generateImage(prompt: String, model: String) {
            // Create placeholder assistant message with a known ID
            let messageId = UUID()
            let generationID = UUID()
            activeImageGenerationID = generationID
            let attachmentGeneration = AttachmentStorage.shared.currentGeneration()
            let placeholderMessage = Message(
                id: messageId,
                role: .assistant,
                content: "",
                model: model,
                mediaType: .image
            )
            conversationManager.addMessage(to: conversation, message: placeholderMessage)
            imageRequestTracker.begin(messageId)

            // Find previous image path (cheap, no disk I/O)
            let previousImagePath = findPreviousImagePath()

            // Load previous image data off MainActor to avoid blocking the UI
            let preparationTask = Task {
                defer { imageRequestTracker.finishPreparation(messageId) }
                var previousImage: Data?
                if let path = previousImagePath {
                    previousImage = await Task.detached(priority: .userInitiated) {
                        AttachmentStorage.shared.load(path: path)
                    }.value
                }
                guard !Task.isCancelled,
                      activeImageGenerationID == generationID,
                      isImageRequestCurrent(
                          messageId: messageId,
                          attachmentGeneration: attachmentGeneration
                      )
                else {
                    guard activeImageGenerationID == generationID else { return }
                    finalizeInvalidatedImageRequest(messageId)
                    activeImageGenerationID = nil
                    isGenerating = false
                    return
                }

                if let previousImage {
                    logChat("📝 Using image edit API with previous image context", level: .info)

                    let handle = aiService.editImage(
                        prompt: prompt,
                        sourceImage: previousImage,
                        model: model,
                        onComplete: { imageData in
                            Task { @MainActor in
                                guard activeImageGenerationID == generationID,
                                      imageRequestTracker.isActive(messageId)
                                else { return }
                                handleImageGenerationSuccess(
                                    imageData: imageData,
                                    messageId: messageId,
                                    attachmentGeneration: attachmentGeneration,
                                    generationID: generationID
                                )
                            }
                        },
                        onError: { error in
                            Task { @MainActor in
                                guard imageRequestTracker.finish(messageId),
                                      activeImageGenerationID == generationID
                                else { return }
                                handleImageGenerationError(
                                    error: error,
                                    messageId: messageId,
                                    generationID: generationID
                                )
                            }
                        }
                    )
                    if let handle {
                        imageRequestTracker.register(handle, for: messageId)
                    }
                } else {
                    let handle = aiService.generateImage(
                        prompt: prompt,
                        model: model,
                        onComplete: { imageData in
                            Task { @MainActor in
                                guard activeImageGenerationID == generationID,
                                      imageRequestTracker.isActive(messageId)
                                else { return }
                                handleImageGenerationSuccess(
                                    imageData: imageData,
                                    messageId: messageId,
                                    attachmentGeneration: attachmentGeneration,
                                    generationID: generationID
                                )
                            }
                        },
                        onError: { error in
                            Task { @MainActor in
                                guard imageRequestTracker.finish(messageId),
                                      activeImageGenerationID == generationID
                                else { return }
                                handleImageGenerationError(
                                    error: error,
                                    messageId: messageId,
                                    generationID: generationID
                                )
                            }
                        }
                    )
                    if let handle {
                        imageRequestTracker.register(handle, for: messageId)
                    }
                }
            }
            imageRequestTracker.registerPreparation(preparationTask, for: messageId)
        }

        func handleImageGenerationSuccess(
            imageData: Data,
            messageId: UUID,
            attachmentGeneration: AttachmentStorageGeneration,
            generationID: UUID
        ) {
            guard activeImageGenerationID == generationID,
                  isImageRequestCurrent(
                      messageId: messageId,
                      attachmentGeneration: attachmentGeneration
                  )
            else {
                if activeImageGenerationID == generationID {
                    finalizeInvalidatedImageRequest(messageId)
                    activeImageGenerationID = nil
                    isGenerating = false
                }
                return
            }

            // Save image to disk off MainActor to avoid blocking the UI
            Task {
                let imagePath = await Task.detached(priority: .userInitiated) {
                    try? AttachmentStorage.shared.save(
                        data: imageData,
                        extension: "png",
                        generation: attachmentGeneration
                    )
                }.value

                guard isImageRequestCurrent(
                    messageId: messageId,
                    attachmentGeneration: attachmentGeneration
                ), activeImageGenerationID == generationID else {
                    if let imagePath {
                        AttachmentStorage.shared.delete(path: imagePath)
                    }
                    if activeImageGenerationID == generationID {
                        finalizeInvalidatedImageRequest(messageId)
                        activeImageGenerationID = nil
                        isGenerating = false
                    }
                    return
                }
                guard imageRequestTracker.finish(messageId) else {
                    if let imagePath {
                        AttachmentStorage.shared.delete(path: imagePath)
                    }
                    return
                }

                if imagePath == nil {
                    logChat("❌ Failed to save generated image to disk", level: .error)
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

                activeImageGenerationID = nil
                isGenerating = false
            }
        }

        func handleImageGenerationError(error: Error, messageId: UUID, generationID: UUID) {
            guard activeImageGenerationID == generationID else { return }
            activeImageGenerationID = nil
            isGenerating = false
            errorMessage = ErrorPresenter.userMessage(for: error)
            errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)

            // Remove the empty assistant placeholder message since we show error in banner
            if let index = conversationManager.conversations.firstIndex(where: {
                $0.id == conversation.id
            }) {
                if let messageIndex = conversationManager.conversations[index].messages.firstIndex(where: {
                    $0.id == messageId
                }) {
                    conversationManager.conversations[index].messages.remove(at: messageIndex)
                }
            }
        }

        /// Generates images from multiple models in parallel for comparison
        func generateMultiModelImages(prompt: String, models: [String]) {
            let generationID = UUID()
            activeImageGenerationID = generationID
            let attachmentGeneration = AttachmentStorage.shared.currentGeneration()
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

            let messageIdsByModel = messageIds

            // Track completion state with actor-isolated counter
            let counter = MainActorCompletionCounter(total: models.count)
            for messageId in messageIds.values {
                imageRequestTracker.begin(messageId)
            }

            // Load previous image off MainActor, then dispatch parallel generations
            let preparationId = UUID()
            let preparationTask = Task {
                defer { imageRequestTracker.finishPreparation(preparationId) }
                var previousImage: Data?
                if let path = previousImagePath {
                    previousImage = await Task.detached(priority: .userInitiated) {
                        AttachmentStorage.shared.load(path: path)
                    }.value
                }
                guard !Task.isCancelled,
                      activeImageGenerationID == generationID,
                      AttachmentStorage.shared.isCurrentGeneration(attachmentGeneration),
                      let currentConversation = conversationManager.conversations.first(where: {
                          $0.id == conversation.id
                      }),
                      messageIdsByModel.values.allSatisfy({ messageId in
                          imageRequestTracker.isActive(messageId)
                              && currentConversation.messages.contains(where: { $0.id == messageId })
                      })
                else {
                    if activeImageGenerationID == generationID {
                        cancelActiveImageRequests()
                        isGenerating = false
                    }
                    return
                }

                if previousImage != nil {
                    logChat("📝 Using image edit API with previous image context for multi-model", level: .info)
                }

                // Generate/edit images in parallel
                for model in models {
                    guard let messageId = messageIdsByModel[model] else { continue }
                    guard activeImageGenerationID == generationID else { return }
                    guard isImageRequestCurrent(
                        messageId: messageId,
                        attachmentGeneration: attachmentGeneration
                    ) else {
                        finalizeInvalidatedImageRequest(messageId)
                        counter.increment()
                        if counter.isComplete {
                            activeImageGenerationID = nil
                            isGenerating = false
                        }
                        continue
                    }

                    let onComplete: @Sendable (Data) -> Void = { imageData in
                        Task { @MainActor in
                            guard activeImageGenerationID == generationID,
                                  isImageRequestCurrent(
                                      messageId: messageId,
                                      attachmentGeneration: attachmentGeneration
                                  )
                            else {
                                if activeImageGenerationID == generationID {
                                    finalizeInvalidatedImageRequest(messageId)
                                    counter.increment()
                                    if counter.isComplete {
                                        activeImageGenerationID = nil
                                        isGenerating = false
                                    }
                                }
                                return
                            }
                            // Save image to disk off MainActor
                            let imagePath = await Task.detached(priority: .userInitiated) {
                                try? AttachmentStorage.shared.save(
                                    data: imageData,
                                    extension: "png",
                                    generation: attachmentGeneration
                                )
                            }.value

                            guard activeImageGenerationID == generationID,
                                  isImageRequestCurrent(
                                      messageId: messageId,
                                      attachmentGeneration: attachmentGeneration
                                  )
                            else {
                                if let imagePath {
                                    AttachmentStorage.shared.delete(path: imagePath)
                                }
                                if activeImageGenerationID == generationID {
                                    finalizeInvalidatedImageRequest(messageId)
                                    counter.increment()
                                    if counter.isComplete {
                                        activeImageGenerationID = nil
                                        isGenerating = false
                                    }
                                }
                                return
                            }
                            guard imageRequestTracker.finish(messageId) else {
                                if let imagePath {
                                    AttachmentStorage.shared.delete(path: imagePath)
                                }
                                return
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
                                conversationManager.saveImmediately(conversationManager.conversations[convIndex])
                            }

                            counter.increment()
                            if counter.isComplete {
                                activeImageGenerationID = nil
                                isGenerating = false
                            }
                        }
                    }

                    let onError: @Sendable (Error) -> Void = { error in
                        Task { @MainActor in
                            guard activeImageGenerationID == generationID,
                                  imageRequestTracker.finish(messageId)
                            else { return }
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
                                activeImageGenerationID = nil
                                isGenerating = false
                            }
                        }
                    }

                    if let sourceImage = previousImage {
                        // Use image editing API
                        let handle = aiService.editImage(
                            prompt: prompt,
                            sourceImage: sourceImage,
                            model: model,
                            onComplete: onComplete,
                            onError: onError
                        )
                        if let handle {
                            imageRequestTracker.register(handle, for: messageId)
                        }
                    } else {
                        // Use image generation API
                        let handle = aiService.generateImage(
                            prompt: prompt,
                            model: model,
                            onComplete: onComplete,
                            onError: onError
                        )
                        if let handle {
                            imageRequestTracker.register(handle, for: messageId)
                        }
                    }
                }
            }
            imageRequestTracker.registerPreparation(preparationTask, for: preparationId)
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
            activeMultiModelResponseGroupID = responseGroupId
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
            let requestOwnerID = UUID()
            activeAIRequestOwnerID = requestOwnerID
            let callbackQueue = OrderedMainActorEventQueue()
            activeMultiModelCallbackQueue = callbackQueue

            // Send to all models in parallel
            aiService.sendToMultipleModels(
                messages: messagesToSend,
                models: models,
                temperature: temperature,
                requestOwnerID: requestOwnerID,
                onChunk: { model, chunk in
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID,
                              let messageId = messageIdsByModel[model],
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
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID,
                              let messageId = messageIdsByModel[model]
                        else { return }

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
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID else { return }
                        activeAIRequestOwnerID = nil
                        if activeMultiModelCallbackQueue === callbackQueue {
                            activeMultiModelCallbackQueue = nil
                        }
                        if activeMultiModelResponseGroupID == responseGroupId {
                            activeMultiModelResponseGroupID = nil
                        }
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
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID
                            || activeAIRequestOwnerID == nil
                        else { return }
                        let isCancellation = error is CancellationError
                            || (error as NSError).code == NSURLErrorCancelled
                        guard let messageId = messageIdsByModel[model] else { return }

                        // Cancellation is silent in the UI, but must leave durable terminal state.
                        if let convIndex = conversationManager.conversations.firstIndex(where: {
                            $0.id == conversationId
                        }),
                            var group = conversationManager.conversations[convIndex].getResponseGroup(responseGroupId)
                        {
                            group.updateStatus(for: messageId, status: .failed)
                            conversationManager.conversations[convIndex].updateResponseGroup(group)
                            if isCancellation {
                                conversationManager.saveImmediately(conversationManager.conversations[convIndex])
                            }
                        }

                        if isCancellation {
                            return
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
                    callbackQueue.enqueue {
                        guard activeAIRequestOwnerID == requestOwnerID,
                              let messageId = messageIdsByModel[model],
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

        func finalizeMultiModelTextResponses(
            conversationId: UUID,
            responseGroupId: UUID
        ) {
            guard let conversationIndex = conversationManager.conversations.firstIndex(where: {
                $0.id == conversationId
            }),
                let groupIndex = conversationManager.conversations[conversationIndex]
                .responseGroups.firstIndex(where: { $0.id == responseGroupId })
            else {
                return
            }

            var didUpdateStatus = false
            for responseIndex in conversationManager.conversations[conversationIndex]
                .responseGroups[groupIndex].responses.indices
                where conversationManager.conversations[conversationIndex]
                .responseGroups[groupIndex].responses[responseIndex].status == .streaming
            {
                conversationManager.conversations[conversationIndex]
                    .responseGroups[groupIndex].responses[responseIndex].status = .failed
                didUpdateStatus = true
            }
            if didUpdateStatus {
                conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            }
        }

        func cancelActiveImageRequests() {
            activeImageGenerationID = nil
            let cancelledMessageIds = imageRequestTracker.cancelAll()
            guard !cancelledMessageIds.isEmpty,
                  let conversationIndex = conversationManager.conversations.firstIndex(where: {
                      $0.id == conversation.id
                  })
            else { return }

            for messageIndex in conversationManager.conversations[conversationIndex].messages.indices
                where cancelledMessageIds.contains(
                    conversationManager.conversations[conversationIndex].messages[messageIndex].id
                )
            {
                conversationManager.conversations[conversationIndex].messages[messageIndex].content =
                    "Image generation cancelled"
                conversationManager.conversations[conversationIndex].messages[messageIndex].mediaType = nil
                conversationManager.conversations[conversationIndex].messages[messageIndex].imageData = nil
                conversationManager.conversations[conversationIndex].messages[messageIndex].imagePath = nil
            }
            for groupIndex in conversationManager.conversations[conversationIndex].responseGroups.indices {
                for responseIndex in conversationManager.conversations[conversationIndex]
                    .responseGroups[groupIndex].responses.indices
                    where cancelledMessageIds.contains(
                        conversationManager.conversations[conversationIndex]
                            .responseGroups[groupIndex].responses[responseIndex].id
                    )
                {
                    conversationManager.conversations[conversationIndex]
                        .responseGroups[groupIndex].responses[responseIndex].status = .failed
                }
            }
            conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
        }
    }

#endif
