//
//  ChatTurnRequestPlan.swift
//  ayna
//
//  Plans the message history sent to AI providers for chat turns.
//

import Foundation

/// Pure request-history plan for a chat turn.
///
/// The Module centralizes two invariants that were previously spread across chat
/// callers: system prompts are prepended consistently, and UI-only assistant
/// placeholders are excluded from provider request histories.
struct ChatTurnRequestPlan: Equatable, Sendable {
    let messages: [Message]

    init(history: [Message], systemPrompt: String?) {
        messages = Self.messages(from: history, systemPrompt: systemPrompt)
    }

    init(conversation: Conversation, systemPrompt: String?, excludingTrailingPlaceholder: Bool) {
        let history = excludingTrailingPlaceholder
            ? Array(conversation.messages.dropLast())
            : conversation.messages
        self.init(history: history, systemPrompt: systemPrompt)
    }

    static func messages(from history: [Message], systemPrompt: String?) -> [Message] {
        var messages = history
        if let systemPrompt, !systemPrompt.isEmpty {
            messages.insert(Message(role: .system, content: systemPrompt), at: 0)
        }
        return messages
    }

    static func effectiveMessages(
        from conversation: Conversation,
        systemPrompt: String?,
        excludingResponseGroupId responseGroupId: UUID? = nil
    ) -> [Message] {
        var history = conversation.getEffectiveHistory()
        if let responseGroupId {
            history.removeAll { $0.responseGroupId == responseGroupId }
        }
        return messages(from: history, systemPrompt: systemPrompt)
    }

    #if !os(watchOS)
        struct ToolResult: Equatable, Sendable {
            let toolCallId: String
            let toolName: String
            let arguments: [String: AnyCodable]
            let result: String
            let shouldSynthesizeToolMessage: Bool

            init(
                toolCallId: String,
                toolName: String,
                arguments: [String: AnyCodable],
                result: String,
                shouldSynthesizeToolMessage: Bool
            ) {
                self.toolCallId = toolCallId
                self.toolName = toolName
                self.arguments = arguments
                self.result = result
                self.shouldSynthesizeToolMessage = shouldSynthesizeToolMessage
            }
        }

        static func toolContinuationMessages(
            conversationMessages: [Message],
            toolResult: ToolResult,
            systemPrompt: String?
        ) -> [Message] {
            var history = Array(conversationMessages.dropLast())

            if toolResult.shouldSynthesizeToolMessage {
                var syntheticToolMessage = Message(role: .tool, content: toolResult.result)
                syntheticToolMessage.toolCalls = [MCPToolCall(
                    id: toolResult.toolCallId,
                    toolName: toolResult.toolName,
                    arguments: toolResult.arguments,
                    result: toolResult.result
                )]
                history.append(syntheticToolMessage)
            }

            return messages(from: history, systemPrompt: systemPrompt)
        }

        static func anyCodableArguments(from arguments: [String: Any]) -> [String: AnyCodable] {
            arguments.reduce(into: [String: AnyCodable]()) { dict, pair in
                dict[pair.key] = AnyCodable(pair.value)
            }
        }
    #endif
}
