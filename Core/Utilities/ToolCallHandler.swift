//
//  ToolCallHandler.swift
//  ayna
//

import Foundation

/// Shared utilities for handling tool calls in chat views.
/// Centralizes tool call creation, message building, and continuation logic
/// that was previously duplicated between MacChatView and MacNewChatView.
#if !os(watchOS)
enum ToolCallHandler {
    /// Creates an MCPToolCall from raw arguments.
    static func createToolCall(
        id: String,
        toolName: String,
        arguments: [String: Any]
    ) -> MCPToolCall {
        let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
            result[pair.key] = AnyCodable(pair.value)
        }
        return MCPToolCall(id: id, toolName: toolName, arguments: anyCodableArgs)
    }

    /// Checks if the tool name is a web search tool.
    static func isWebSearchTool(_ toolName: String) -> Bool {
        toolName == "web_search"
    }

    /// Creates a tool result message with embedded tool call metadata.
    static func createToolMessage(
        toolCallId: String,
        toolName: String,
        arguments: [String: Any],
        result: String
    ) -> Message {
        let anyCodableArgs = arguments.reduce(into: [String: AnyCodable]()) { result, pair in
            result[pair.key] = AnyCodable(pair.value)
        }
        var toolMessage = Message(role: .tool, content: result)
        toolMessage.toolCalls = [
            MCPToolCall(
                id: toolCallId,
                toolName: toolName,
                arguments: anyCodableArgs,
                result: result
            ),
        ]
        return toolMessage
    }

    /// Creates a continuation assistant message for receiving the model's response after tool execution.
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

    /// Builds the message array for the continuation API call after tool execution.
    static func buildContinuationMessages(
        conversationMessages: [Message],
        toolCallId: String,
        toolName: String,
        arguments: [String: Any],
        result: String,
        isWebSearch: Bool,
        systemPrompt: String?
    ) -> [Message] {
        // Exclude the continuation assistant message (last message is our placeholder)
        var messages = Array(conversationMessages.dropLast())

        // For web_search, inject a synthetic tool message for the API only (not stored in conversation)
        if isWebSearch {
            let syntheticToolMessage = createToolMessage(
                toolCallId: toolCallId,
                toolName: toolName,
                arguments: arguments,
                result: result
            )
            messages.append(syntheticToolMessage)
        }

        // Prepend system prompt if configured
        if let systemPrompt {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messages.insert(systemMessage, at: 0)
        }

        return messages
    }
}
#endif
