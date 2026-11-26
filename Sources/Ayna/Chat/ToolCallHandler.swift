#if os(macOS)

    import Foundation

    struct MacQueuedToolCall: @unchecked Sendable {
        let id: String
        let name: String
        let arguments: [String: Any]
    }

    struct MacCompletedToolCall: @unchecked Sendable {
        let toolCall: MacQueuedToolCall
        let result: String
        let citations: [CitationReference]?
    }

    @MainActor
    final class MacToolCallBatchState {
        private var pendingToolCalls: [MacQueuedToolCall] = []
        private var processingToolCalls: [MacQueuedToolCall] = []
        private var queuedToolCallIds: Set<String> = []
        private var isProcessingToolCalls = false

        var hasPendingToolCall: Bool {
            isProcessingToolCalls || !pendingToolCalls.isEmpty
        }

        func enqueue(_ toolCall: MacQueuedToolCall) {
            guard queuedToolCallIds.insert(toolCall.id).inserted else { return }
            pendingToolCalls.append(toolCall)
        }

        func beginProcessing() -> [MacQueuedToolCall]? {
            guard !isProcessingToolCalls, !pendingToolCalls.isEmpty else { return nil }
            isProcessingToolCalls = true
            let toolCalls = pendingToolCalls
            processingToolCalls = toolCalls
            pendingToolCalls.removeAll(keepingCapacity: true)
            return toolCalls
        }

        func finishProcessing() {
            isProcessingToolCalls = false
            processingToolCalls.removeAll(keepingCapacity: true)
        }

        func takeAllToolCalls() -> [MacQueuedToolCall] {
            let toolCalls = pendingToolCalls + processingToolCalls
            pendingToolCalls.removeAll(keepingCapacity: true)
            processingToolCalls.removeAll(keepingCapacity: true)
            isProcessingToolCalls = false
            return toolCalls
        }
    }

    @MainActor
    final class ToolCallHandler {
        static var maxToolCallDepth: Int {
            AgentSettingsStore.shared.settings.maxToolChainDepth
        }

        static func createToolCall(
            id: String,
            toolName: String,
            arguments: [String: Any],
            result: String? = nil
        ) -> MCPToolCall {
            let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { dict, pair in
                dict[pair.key] = AnyCodable(pair.value)
            }

            return MCPToolCall(
                id: id,
                toolName: toolName,
                arguments: anyCodableArgs,
                result: result
            )
        }

        static func createToolMessage(
            toolCallId: String,
            toolName: String,
            arguments: [String: Any],
            result: String
        ) -> Message {
            var message = Message(role: .tool, content: result)
            message.toolCalls = [createToolCall(
                id: toolCallId,
                toolName: toolName,
                arguments: arguments,
                result: result
            )]
            return message
        }

        @discardableResult
        static func insertToolResult(
            _ completedToolCall: MacCompletedToolCall,
            into conversation: inout Conversation
        ) -> Bool {
            let toolCall = completedToolCall.toolCall
            guard let assistantIndex = conversation.messages.lastIndex(where: { message in
                message.role == .assistant
                    && message.toolCalls?.contains(where: { $0.id == toolCall.id }) == true
            }) else {
                return false
            }

            var insertionIndex = assistantIndex + 1
            while insertionIndex < conversation.messages.count,
                  conversation.messages[insertionIndex].role == .tool
            {
                if conversation.messages[insertionIndex].toolCalls?.contains(where: {
                    $0.id == toolCall.id
                }) == true {
                    return true
                }
                insertionIndex += 1
            }
            conversation.messages.insert(
                createToolMessage(
                    toolCallId: toolCall.id,
                    toolName: toolCall.name,
                    arguments: toolCall.arguments,
                    result: completedToolCall.result
                ),
                at: insertionIndex
            )
            return true
        }

        static func createContinuationMessage(
            model: String,
            citations: [CitationReference]? = nil
        ) -> Message {
            var message = Message(role: .assistant, content: "", model: model)
            if let citations {
                message.citations = citations
            }
            return message
        }

        static func isWebSearchTool(_ toolName: String) -> Bool {
            toolName == "web_search"
        }

        static func buildContinuationMessages(
            conversationMessages: [Message],
            toolCallId: String,
            toolName: String,
            arguments: [String: Any],
            result: String,
            isWebSearch: Bool,
            systemPrompt: String?
        ) -> [Message] {
            let completedToolCall = MacCompletedToolCall(
                toolCall: MacQueuedToolCall(
                    id: toolCallId,
                    name: toolName,
                    arguments: arguments
                ),
                result: result,
                citations: nil
            )
            let messagesBeforeContinuation = Array(conversationMessages.dropLast())
            let currentAssistantIndex = messagesBeforeContinuation.lastIndex(where: { message in
                message.role == .assistant
                    && message.toolCalls?.contains(where: { $0.id == toolCallId }) == true
            })
            var currentTurnAlreadyHasResult = false
            if let currentAssistantIndex {
                var resultIndex = currentAssistantIndex + 1
                while resultIndex < messagesBeforeContinuation.count,
                      messagesBeforeContinuation[resultIndex].role == .tool
                {
                    if messagesBeforeContinuation[resultIndex].toolCalls?.contains(where: {
                        $0.id == toolCallId
                    }) == true {
                        currentTurnAlreadyHasResult = true
                        break
                    }
                    resultIndex += 1
                }
            }
            var messages = buildContinuationMessages(
                conversationMessages: conversationMessages,
                completedToolCalls: [completedToolCall],
                systemPrompt: systemPrompt
            )
            if isWebSearch, !currentTurnAlreadyHasResult {
                messages.append(createToolMessage(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    arguments: arguments,
                    result: result
                ))
            }
            return messages
        }

        static func buildContinuationMessages(
            conversationMessages: [Message],
            completedToolCalls _: [MacCompletedToolCall],
            systemPrompt: String?
        ) -> [Message] {
            var messages = Array(conversationMessages.dropLast())

            if let systemPrompt {
                messages.insert(Message(role: .system, content: systemPrompt), at: 0)
            }

            return messages
        }
    }

#endif
