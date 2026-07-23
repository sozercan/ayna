//
//  ToolCallAnnotationPlan.swift
//  ayna
//
//  Plans how pending tool calls are annotated on assistant messages.
//

import Foundation

#if !os(watchOS)
    /// Pure plan for adding a pending tool-call annotation to an assistant message.
    ///
    /// The merge policy makes existing platform behavior explicit: existing-chat
    /// macOS appends callbacks to the current assistant message, while new-chat
    /// and iOS replace the pending annotation for the current callback.
    struct ToolCallAnnotationPlan: Equatable, Sendable {
        enum MergePolicy: Equatable, Sendable {
            case append
            case replace
        }

        let toolCall: MCPToolCall
        let toolCalls: [MCPToolCall]

        init(
            existingToolCalls: [MCPToolCall]?,
            toolCallId: String,
            toolName: String,
            arguments: [String: Any],
            result: String? = nil,
            mergePolicy: MergePolicy
        ) {
            toolCall = MCPToolCall(
                id: toolCallId,
                toolName: toolName,
                arguments: ChatTurnRequestPlan.anyCodableArguments(from: arguments),
                result: result
            )

            switch mergePolicy {
            case .append:
                toolCalls = (existingToolCalls ?? []) + [toolCall]
            case .replace:
                toolCalls = [toolCall]
            }
        }
    }
#endif
