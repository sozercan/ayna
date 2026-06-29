//
//  ToolContinuationPlan.swift
//  ayna
//
//  Plans transcript and request messages after a tool result is available.
//

import Foundation

#if !os(watchOS)
    /// Pure plan for continuing a chat turn after a tool result.
    ///
    /// The plan owns the web-search special case: web search results are hidden
    /// from the transcript but synthesized into provider request history, and
    /// citations are attached to the continuation assistant placeholder.
    struct ToolContinuationPlan: Equatable, Sendable {
        let toolCall: MCPToolCall
        let visibleToolMessage: Message?
        let continuationAssistantMessage: Message
        let requestMessages: [Message]

        init(
            existingMessages: [Message],
            toolCallId: String,
            toolName: String,
            arguments: [String: Any],
            result: String,
            model: String,
            citations: [CitationReference]?,
            systemPrompt: String?
        ) {
            let anyCodableArguments = ChatTurnRequestPlan.anyCodableArguments(from: arguments)
            let isWebSearch = Self.isWebSearchTool(toolName)
            let toolCall = MCPToolCall(
                id: toolCallId,
                toolName: toolName,
                arguments: anyCodableArguments,
                result: result
            )

            var visibleToolMessage: Message?
            if !isWebSearch {
                var toolMessage = Message(role: .tool, content: result)
                toolMessage.toolCalls = [toolCall]
                visibleToolMessage = toolMessage
            }

            var continuationAssistantMessage = Message(role: .assistant, content: "", model: model)
            if isWebSearch, let citations {
                continuationAssistantMessage.citations = citations
            }

            var plannedTranscriptMessages = existingMessages
            if let visibleToolMessage {
                plannedTranscriptMessages.append(visibleToolMessage)
            }
            plannedTranscriptMessages.append(continuationAssistantMessage)

            self.toolCall = toolCall
            self.visibleToolMessage = visibleToolMessage
            self.continuationAssistantMessage = continuationAssistantMessage
            requestMessages = ChatTurnRequestPlan.toolContinuationMessages(
                conversationMessages: plannedTranscriptMessages,
                excludingAssistantPlaceholderId: continuationAssistantMessage.id,
                toolResult: ChatTurnRequestPlan.ToolResult(
                    toolCallId: toolCallId,
                    toolName: toolName,
                    arguments: anyCodableArguments,
                    result: result,
                    shouldSynthesizeToolMessage: isWebSearch
                ),
                systemPrompt: systemPrompt
            )
        }

        static func isWebSearchTool(_ toolName: String) -> Bool {
            toolName == "web_search"
        }
    }
#endif

