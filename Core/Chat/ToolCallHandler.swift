//
//  ToolCallHandler.swift
//  ayna
//
//  Extracted from MacChatView/MacNewChatView - handles tool call execution
//

import Foundation

/// Handles tool call execution and response processing
@MainActor
final class ToolCallHandler {

    /// Maximum tool call depth from settings
    static var maxToolCallDepth: Int {
        AgentSettingsStore.shared.settings.maxToolChainDepth
    }

    // MARK: - Tool Call Storage

    /// Creates an MCPToolCall from the callback parameters
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

    /// Creates a tool message with the execution result
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

    /// Creates a continuation assistant message for tool chain
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

    /// Checks if a tool is web_search (which has special handling)
    static func isWebSearchTool(_ toolName: String) -> Bool {
        toolName == "web_search"
    }

    // MARK: - Message Building for Tool Continuations

    /// Builds the messages array for continuing after tool execution
    /// - Parameters:
    ///   - conversation: The conversation with all messages including the new assistant placeholder
    ///   - toolCallId: The tool call ID
    ///   - toolName: The tool name
    ///   - arguments: The tool arguments
    ///   - result: The tool execution result
    ///   - isWebSearch: Whether this is a web_search tool (synthetic message)
    ///   - systemPrompt: Optional system prompt to prepend
    /// - Returns: Array of messages ready for the API
    static func buildContinuationMessages(
        conversationMessages: [Message],
        toolCallId: String,
        toolName: String,
        arguments: [String: Any],
        result: String,
        isWebSearch: Bool,
        systemPrompt: String?
    ) -> [Message] {
        // Exclude the continuation assistant message (last one)
        var messages = Array(conversationMessages.dropLast())

        if isWebSearch {
            // Append a synthetic tool message for the API only (not stored)
            let syntheticToolMessage = createToolMessage(
                toolCallId: toolCallId,
                toolName: toolName,
                arguments: arguments,
                result: result
            )
            messages.append(syntheticToolMessage)
        }

        // Prepend system prompt if provided
        if let systemPrompt {
            let systemMessage = Message(role: .system, content: systemPrompt)
            messages.insert(systemMessage, at: 0)
        }

        return messages
    }
}
