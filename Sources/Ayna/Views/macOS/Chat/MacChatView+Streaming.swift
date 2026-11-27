// swiftformat:options --ifdef no-indent
#if os(macOS)

import SwiftUI

extension MacChatView {
    private struct ToolStreamContext {
        let operationID: ToolChainCoordinator.OperationID
        let requestRoundID: ToolCallRequestRoundCoordinator<ToolExecutionResult>.RequestRoundID
        let conversationID: UUID
        let assistantMessageID: UUID
        let model: String
        let temperature: Double
        let maxToolCallDepth: Int
        let toolsWrapper: UncheckedSendableWrapper<[[String: Any]]?>
    }

    func clearToolChainTimeout() {
        toolChainTimeoutTask?.cancel()
        toolChainTimeoutTask = nil
        toolChainTimeoutContext = nil
    }

    func hasPendingApprovals(for conversationID: UUID) -> Bool {
        (aiService.permissionService?.pendingCount(forConversation: conversationID) ?? 0) > 0
    }

    func syncToolChainTimeoutForPendingApprovals() {
        guard let context = toolChainTimeoutContext else { return }
        guard toolChainCoordinator.owns(context.operationID, conversationID: context.conversationID),
              activeAssistantMessageID == context.assistantMessageID
        else {
            clearToolChainTimeout()
            return
        }

        if hasPendingApprovals(for: context.conversationID) {
            toolChainTimeoutTask?.cancel()
            toolChainTimeoutTask = nil
        } else if toolChainTimeoutTask == nil {
            startToolChainTimeoutTask(for: context)
        }
    }

    func armToolChainTimeout(
        operationID: ToolChainCoordinator.OperationID,
        assistantMessageID: UUID,
        conversationID: UUID
    ) {
        let context = ToolChainTimeoutContext(
            operationID: operationID,
            assistantMessageID: assistantMessageID,
            conversationID: conversationID
        )
        toolChainTimeoutContext = context
        toolChainTimeoutTask?.cancel()
        toolChainTimeoutTask = nil
        guard !hasPendingApprovals(for: conversationID) else { return }
        startToolChainTimeoutTask(for: context)
    }

    private func startToolChainTimeoutTask(for context: ToolChainTimeoutContext) {
        toolChainTimeoutTask?.cancel()
        let coordinator = toolChainCoordinator
        let operationID = context.operationID
        let assistantMessageID = context.assistantMessageID
        let conversationID = context.conversationID
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled,
                  coordinator.owns(operationID, conversationID: conversationID),
                  activeAssistantMessageID == assistantMessageID,
                  !hasPendingApprovals(for: conversationID)
            else {
                return
            }

            logChat("⏰ Tool execution timeout after 60s, cancelling owned work", level: .error)
            abortOwnedTextGeneration(operationID: operationID, conversationID: conversationID)
            errorMessage = "Tool execution timed out after 60 seconds"
        }
        toolChainTimeoutTask = timeoutTask
        coordinator.track(timeoutTask, for: operationID)
    }

    func flushPendingChunks(
        operationID: ToolChainCoordinator.OperationID,
        conversationId: UUID,
        assistantMessageID: UUID
    ) {
        batchUpdateTask = nil
        let chunksToProcess = pendingChunks
        pendingChunks.removeAll()
        guard !chunksToProcess.isEmpty,
              toolChainCoordinator.owns(operationID, conversationID: conversationId),
              activeAssistantMessageID == assistantMessageID
        else {
            return
        }

        guard conversationManager.appendToMessage(
            conversationId: conversationId,
            messageId: assistantMessageID,
            chunk: chunksToProcess.joined()
        ) else {
            logChat(
                "⚠️ Assistant message no longer exists, ignoring chunk",
                level: .info,
                metadata: ["messageId": assistantMessageID.uuidString]
            )
            return
        }
        if let conversation = conversationManager.conversation(byId: conversationId) {
            conversationManager.save(conversation)
        }
        currentToolName = nil
    }

    func sendMessageWithToolSupport(
        messages: [Message],
        model: String,
        temperature: Double,
        tools: [[String: Any]]?,
        isInitialRequest _: Bool,
        assistantMessageID requestedAssistantMessageID: UUID? = nil,
        operationID existingOperationID: ToolChainCoordinator.OperationID? = nil
    ) {
        let conversationId = conversation.id
        let coordinator = toolChainCoordinator
        let requestRounds = toolCallRequestRoundCoordinator
        guard let assistantMessageID = requestedAssistantMessageID
            ?? conversationManager.conversation(byId: conversationId)?.messages.last(where: { $0.role == .assistant })?.id
        else {
            isGenerating = false
            return
        }
        activeAssistantMessageID = assistantMessageID

        let operationID = resolveToolChainOperationID(
            existingOperationID: existingOperationID,
            conversationId: conversationId
        )

        guard coordinator.owns(operationID, conversationID: conversationId),
              let requestRoundID = requestRounds.beginRequestRound(
                  for: operationID,
                  coordinatedBy: coordinator
              )
        else {
            return
        }

        let context = ToolStreamContext(
            operationID: operationID,
            requestRoundID: requestRoundID,
            conversationID: conversationId,
            assistantMessageID: assistantMessageID,
            model: model,
            temperature: temperature,
            maxToolCallDepth: AgentSettingsStore.shared.settings.maxToolChainDepth,
            toolsWrapper: UncheckedSendableWrapper(tools)
        )
        let toolCallAdmissionGate = ToolCallRequestAdmissionGate()

        let request = aiService.sendMessage(
            messages: messages,
            model: model,
            temperature: temperature,
            tools: tools,
            conversationId: conversationId,
            onChunk: { chunk in
                coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                    handleStreamChunk(chunk, context: context)
                }
            },
            onComplete: {
                coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                    handleStreamComplete(context: context)
                }
            },
            onError: { error in
                coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                    handleStreamError(error, context: context)
                }
            },
            onToolCallRequested: toolCallAdmissionGate.admittedCallback { toolCallId, toolName, arguments in
                let argumentsWrapper = UncheckedSendableWrapper(arguments)
                coordinator.enqueueCallback(for: operationID, conversationID: conversationId) {
                    handleToolCallRequested(
                        toolCallId: toolCallId,
                        toolName: toolName,
                        argumentsWrapper: argumentsWrapper,
                        context: context
                    )
                }
            }
        )
        coordinator.track(request, for: operationID)
    }

    private func resolveToolChainOperationID(
        existingOperationID: ToolChainCoordinator.OperationID?,
        conversationId: UUID
    ) -> ToolChainCoordinator.OperationID {
        if let existingOperationID {
            return existingOperationID
        }
        activeMultiModelResponseGroupID = nil
        batchUpdateTask?.cancel()
        batchUpdateTask = nil
        pendingChunks.removeAll()
        toolCallDepth = 0
        return toolChainCoordinator.beginOperation(conversationID: conversationId)
    }

    private func handleStreamChunk(_ chunk: String, context: ToolStreamContext) {
        guard activeAssistantMessageID == context.assistantMessageID else { return }
        pendingChunks.append(chunk)
        if let pending = batchUpdateTask, !pending.isCancelled { return }

        let batchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            flushPendingChunks(
                operationID: context.operationID,
                conversationId: context.conversationID,
                assistantMessageID: context.assistantMessageID
            )
        }
        batchUpdateTask = batchTask
        toolChainCoordinator.track(batchTask, for: context.operationID)
    }

    private func handleStreamComplete(context: ToolStreamContext) {
        guard activeAssistantMessageID == context.assistantMessageID else { return }
        batchUpdateTask?.cancel()
        batchUpdateTask = nil

        if !pendingChunks.isEmpty {
            let remainingChunks = pendingChunks.joined()
            pendingChunks.removeAll()
            conversationManager.appendToMessage(
                conversationId: context.conversationID,
                messageId: context.assistantMessageID,
                chunk: remainingChunks
            )
        }
        if let conversation = conversationManager.conversation(byId: context.conversationID) {
            conversationManager.saveImmediately(conversation)
        }

        let resolution = toolCallRequestRoundCoordinator.providerDidComplete(
            operationID: context.operationID,
            requestRoundID: context.requestRoundID
        )
        handleToolRoundResolution(
            resolution,
            operationID: context.operationID,
            sourceAssistantMessageID: context.assistantMessageID,
            conversationID: context.conversationID,
            model: context.model,
            temperature: context.temperature,
            tools: context.toolsWrapper.value
        )
    }

    private func handleStreamError(_ error: Error, context: ToolStreamContext) {
        guard activeAssistantMessageID == context.assistantMessageID else { return }
        guard toolChainCoordinator.owns(context.operationID, conversationID: context.conversationID) else { return }
        abortOwnedTextGeneration(operationID: context.operationID, conversationID: context.conversationID)
        if !(error is CancellationError) {
            logChat(
                "❌ Stream error",
                level: .error,
                metadata: ["error": error.localizedDescription]
            )
            errorMessage = ErrorPresenter.userMessage(for: error)
            errorRecoverySuggestion = ErrorPresenter.recoverySuggestion(for: error)
        }
    }

    private func handleToolCallRequested(
        toolCallId: String,
        toolName: String,
        argumentsWrapper: UncheckedSendableWrapper<[String: Any]>,
        context: ToolStreamContext
    ) {
        guard activeAssistantMessageID == context.assistantMessageID,
              let token = toolCallRequestRoundCoordinator.registerTool(
                  for: context.operationID,
                  requestRoundID: context.requestRoundID
              )
        else {
            return
        }

        if token.registrationIndex == 0 {
            guard toolCallDepth < context.maxToolCallDepth else {
                logChat("⚠️ Max tool call depth reached, stopping", level: .error)
                abortOwnedTextGeneration(operationID: context.operationID, conversationID: context.conversationID)
                errorMessage = "Tool call limit reached. Please try again."
                return
            }
            toolCallDepth += 1
            armToolChainTimeout(
                operationID: context.operationID,
                assistantMessageID: context.assistantMessageID,
                conversationID: context.conversationID
            )
        }

        currentToolName = toolName
        let anyCodableArguments = argumentsWrapper.value.reduce(into: [String: AnyCodable]()) { result, pair in
            result[pair.key] = AnyCodable(pair.value)
        }
        recordRequestedToolCall(
            toolCallId: toolCallId,
            toolName: toolName,
            arguments: anyCodableArguments,
            context: context
        )

        toolChainCoordinator.schedule(for: context.operationID, conversationID: context.conversationID) {
            await executeToolCall(
                token: token,
                toolCallId: toolCallId,
                toolName: toolName,
                argumentsWrapper: argumentsWrapper,
                anyCodableArguments: anyCodableArguments,
                context: context
            )
        }
    }

    private func recordRequestedToolCall(
        toolCallId: String,
        toolName: String,
        arguments: [String: AnyCodable],
        context: ToolStreamContext
    ) {
        let toolCall = MCPToolCall(
            id: toolCallId,
            toolName: toolName,
            arguments: arguments
        )
        conversationManager.updateMessage(
            conversationId: context.conversationID,
            messageId: context.assistantMessageID
        ) { message in
            var calls = message.toolCalls ?? []
            if !calls.contains(where: { $0.id == toolCallId }) {
                calls.append(toolCall)
            }
            message.toolCalls = calls
        }
        if let conversation = conversationManager.conversation(byId: context.conversationID) {
            conversationManager.save(conversation)
        }
    }

    private func executeToolCall(
        token: ToolCallRequestRoundCoordinator<ToolExecutionResult>.ToolToken,
        toolCallId: String,
        toolName: String,
        argumentsWrapper: UncheckedSendableWrapper<[String: Any]>,
        anyCodableArguments: [String: AnyCodable],
        context: ToolStreamContext
    ) async {
        let coordinator = toolChainCoordinator
        guard coordinator.owns(context.operationID, conversationID: context.conversationID),
              activeAssistantMessageID == context.assistantMessageID,
              !Task.isCancelled
        else {
            return
        }

        let result: ToolExecutionResult
        do {
            logChat(
                "⚙️ Executing tool: \(toolName)",
                level: .info,
                metadata: ["toolName": toolName]
            )

            let output: String
            let citations: [CitationReference]?
            if aiService.isBuiltInTool(toolName) {
                (output, citations) = await aiService.executeBuiltInToolWithCitations(
                    name: toolName,
                    arguments: argumentsWrapper.value,
                    conversationId: context.conversationID
                )
            } else {
                output = try await MCPServerManager.shared.executeTool(
                    name: toolName,
                    arguments: argumentsWrapper.value
                )
                citations = nil
            }
            guard coordinator.owns(context.operationID, conversationID: context.conversationID),
                  activeAssistantMessageID == context.assistantMessageID,
                  !Task.isCancelled
            else {
                return
            }
            result = ToolExecutionResult(
                callID: toolCallId,
                toolName: toolName,
                arguments: anyCodableArguments,
                output: output,
                citations: citations ?? []
            )
        } catch is CancellationError {
            return
        } catch {
            guard coordinator.owns(context.operationID, conversationID: context.conversationID),
                  activeAssistantMessageID == context.assistantMessageID,
                  !Task.isCancelled
            else {
                return
            }
            logChat(
                "❌ Tool execution failed: \(error.localizedDescription)",
                level: .error,
                metadata: ["toolName": toolName, "error": error.localizedDescription]
            )
            result = ToolExecutionResult(
                callID: toolCallId,
                toolName: toolName,
                arguments: anyCodableArguments,
                output: "ERROR: \(error.localizedDescription)"
            )
        }

        let resolution = toolCallRequestRoundCoordinator.toolDidComplete(token, result: result)
        handleToolRoundResolution(
            resolution,
            operationID: context.operationID,
            sourceAssistantMessageID: context.assistantMessageID,
            conversationID: context.conversationID,
            model: context.model,
            temperature: context.temperature,
            tools: context.toolsWrapper.value
        )
    }

    private func handleToolRoundResolution(
        _ resolution: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Resolution,
        operationID: ToolChainCoordinator.OperationID,
        sourceAssistantMessageID: UUID,
        conversationID: UUID,
        model: String,
        temperature: Double,
        tools: [[String: Any]]?
    ) {
        switch resolution {
        case .pending:
            return
        case .ignored:
            return
        case .responseCompleted:
            clearToolChainTimeout()
            guard toolChainCoordinator.finishOperation(operationID) else { return }
            activeAssistantMessageID = nil
            currentToolName = nil
            toolCallDepth = 0
            isGenerating = false
            failedMessage = nil
            failedSendPayload = nil
        case let .launchContinuation(continuation):
            clearToolChainTimeout()
            launchToolContinuation(
                continuation,
                operationID: operationID,
                sourceAssistantMessageID: sourceAssistantMessageID,
                conversationID: conversationID,
                model: model,
                temperature: temperature,
                tools: tools
            )
        }
    }

    private func launchToolContinuation(
        _ continuation: ToolCallRequestRoundCoordinator<ToolExecutionResult>.Continuation,
        operationID: ToolChainCoordinator.OperationID,
        sourceAssistantMessageID: UUID,
        conversationID: UUID,
        model: String,
        temperature: Double,
        tools: [[String: Any]]?
    ) {
        guard toolChainCoordinator.owns(operationID, conversationID: conversationID),
              continuation.operationID == operationID,
              activeAssistantMessageID == sourceAssistantMessageID,
              let conversation = conversationManager.conversation(byId: conversationID)
        else {
            return
        }

        let results = continuation.toolResults.map(\.result)
        for result in results {
            conversationManager.addMessage(to: conversation, message: result.makeMessage())
        }

        let citations = ToolExecutionResult.combinedCitations(from: results)
        let continuationMessage = ToolCallHandler.createContinuationMessage(
            model: model,
            citations: citations.isEmpty ? nil : citations
        )
        conversationManager.addMessage(to: conversation, message: continuationMessage)

        guard let conversationWithAssistant = conversationManager.conversation(byId: conversationID),
              toolChainCoordinator.owns(operationID, conversationID: conversationID)
        else {
            return
        }

        var history = conversationWithAssistant
        history.messages.removeAll { $0.id == continuationMessage.id }
        var continuationMessages = history.getEffectiveHistory()
        if let systemPrompt = buildFullSystemPrompt(for: conversationWithAssistant) {
            continuationMessages.insert(Message(role: .system, content: systemPrompt), at: 0)
        }

        currentToolName = nil
        sendMessageWithToolSupport(
            messages: continuationMessages,
            model: model,
            temperature: temperature,
            tools: tools,
            isInitialRequest: false,
            assistantMessageID: continuationMessage.id,
            operationID: operationID
        )
    }
}
#endif
