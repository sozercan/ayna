#if os(macOS)
    //
    //  MacNewChatView+Lifecycle.swift
    //  ayna
    //
    //  Cancellation finalization for the macOS new-chat flow.
    //

    import SwiftUI

    extension MacNewChatView {
        func cancelOwnedGenerationForLifecycle() {
            cancelSendPreparation()
            toolChainCoordinator.cancelCurrentOperation {
                finalizePersistedTextGeneration()
            }
            imageGenerationCoordinator.cancelCurrentOperation()
            activeAssistantMessageID = nil
            activeMultiModelResponseGroupID = nil
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
        }

        func abortOwnedTextGeneration(
            operationID: ToolChainCoordinator.OperationID,
            conversationID: UUID
        ) {
            guard toolChainCoordinator.owns(operationID, conversationID: conversationID) else { return }
            finalizePersistedTextGeneration()
            toolChainCoordinator.cancelCurrentOperation()
            activeAssistantMessageID = nil
            activeMultiModelResponseGroupID = nil
            isGenerating = false
            currentToolName = nil
            toolCallDepth = 0
        }

        func finalizePersistedTextGeneration() {
            let assistantMessageID = activeAssistantMessageID
            let responseGroupID = activeMultiModelResponseGroupID
            guard assistantMessageID != nil || responseGroupID != nil,
                  let conversationID = currentConversationId,
                  let conversationIndex = conversationManager.conversations.firstIndex(where: { $0.id == conversationID })
            else {
                activeMultiModelResponseGroupID = nil
                return
            }

            ChatGenerationFinalizer.finalize(
                conversation: &conversationManager.conversations[conversationIndex],
                activeAssistantMessageID: assistantMessageID,
                activeResponseGroupID: responseGroupID
            )
            conversationManager.saveImmediately(conversationManager.conversations[conversationIndex])
            activeMultiModelResponseGroupID = nil
        }
    }
#endif
